#if canImport(CoreBluetooth) && canImport(Observation)
import Foundation
import CoreBluetooth
import Observation

/// A scale seen during scanning.
public struct DiscoveredScale: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var driverID: String
    public var driverName: String
    public var rssi: Int
}

/// CoreBluetooth central for food scales: scan → match driver → connect → subscribe → parse → stable detection.
///
/// UI observes `state`, `latestReading` and `stableGrams`. In the Simulator (or when `simulate` is true)
/// a `MockScaleSignal` replaces Bluetooth so the full scale-logging flow can be exercised.
@MainActor
@Observable
public final class FoodScaleManager {
    public enum State: Equatable, Sendable {
        case idle, poweredOff, unauthorized, unsupported, scanning
        case connecting(String)
        case connected(String)
        case failed(String)

        public var isConnected: Bool { if case .connected = self { return true }; return false }
    }

    public private(set) var state: State = .idle
    public private(set) var discovered: [DiscoveredScale] = []
    /// Latest net reading in grams (software tare applied).
    public private(set) var latestReading: WeightReading?
    /// Set when the weight settles (±1 g for 1 s); cleared when it moves again.
    public private(set) var stableGrams: Double?
    public private(set) var connectedDriverName: String?

    public let registry: FoodScaleRegistry
    public let simulate: Bool

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var proxy: BLEProxy?
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var drivers: [UUID: any FoodScaleDriver] = [:]
    @ObservationIgnored private var activePeripheral: CBPeripheral?
    @ObservationIgnored private var activeDriver: (any FoodScaleDriver)?
    @ObservationIgnored private var detector = StableWeightDetector()
    @ObservationIgnored private var softwareTareGrams: Double = 0
    @ObservationIgnored private var rawGrams: Double = 0
    @ObservationIgnored private var simulationTask: Task<Void, Never>?
    @ObservationIgnored private var wantsScan = false

    public init(registry: FoodScaleRegistry = .standard, simulate: Bool? = nil) {
        #if targetEnvironment(simulator)
        let useSimulator = simulate ?? true
        #else
        let useSimulator = simulate ?? false
        #endif
        self.simulate = useSimulator
        self.registry = useSimulator ? .simulator : registry
    }

    // MARK: Public API

    public func startScan() {
        discovered = []
        if simulate {
            state = .scanning
            discovered = [DiscoveredScale(id: UUID(), name: MockFoodScaleDriver.localName, driverID: MockFoodScaleDriver().id,
                                          driverName: MockFoodScaleDriver().displayName, rssi: -40)]
            return
        }
        wantsScan = true
        if central == nil {
            let proxy = BLEProxy(owner: self)
            self.proxy = proxy
            // Callbacks on the main queue so we can hop into MainActor isolation synchronously.
            central = CBCentralManager(delegate: proxy, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        } else {
            beginScanIfReady()
        }
    }

    public func stopScan() {
        wantsScan = false
        central?.stopScan()
        if state == .scanning { state = .idle }
    }

    public func connect(_ scale: DiscoveredScale) {
        stopScan()
        if simulate {
            activeDriver = MockFoodScaleDriver()
            connectedDriverName = scale.name
            state = .connected(scale.name)
            startSimulation()
            return
        }
        guard let peripheral = peripherals[scale.id], let driver = drivers[scale.id] else { return }
        activePeripheral = peripheral
        activeDriver = driver
        state = .connecting(scale.name)
        central?.connect(peripheral, options: nil)
    }

    public func disconnect() {
        simulationTask?.cancel(); simulationTask = nil
        if let p = activePeripheral { central?.cancelPeripheralConnection(p) }
        activePeripheral = nil; activeDriver = nil; connectedDriverName = nil
        latestReading = nil; stableGrams = nil
        detector.reset()
        state = .idle
    }

    /// Zeroes the scale: hardware tare when the driver supports it, otherwise software tare.
    public func tare() {
        detector.reset()
        stableGrams = nil
        if !simulate, let command = activeDriver?.tareCommand(), let p = activePeripheral, write(command, to: p) {
            softwareTareGrams = 0
            return
        }
        softwareTareGrams = rawGrams
        if simulate { simulationTask?.cancel(); startSimulation(restart: true) }
    }

    /// Simulator only: place a new item of `grams` on the platform.
    public func simulatePlacing(grams: Double) {
        guard simulate else { return }
        startSimulation(restart: true, target: grams)
    }

    // MARK: Reading pipeline

    func handle(value: Data, characteristicUUID: String) {
        guard let driver = activeDriver,
              let reading = driver.parse(characteristicUUID: characteristicUUID, value: value, receivedAt: Date()) else { return }
        ingest(reading)
    }

    func ingest(_ reading: WeightReading) {
        rawGrams = reading.grams
        var net = reading
        net.grams = (reading.grams - softwareTareGrams)
        latestReading = net
        if let stable = detector.add(grams: net.grams, at: reading.timestamp) {
            stableGrams = stable
        } else if reading.isStable, net.grams > detector.minimumGrams, stableGrams == nil {
            stableGrams = (net.grams * 10).rounded() / 10
        } else if let s = stableGrams, abs(net.grams - s) > detector.tolerance {
            stableGrams = nil
        }
    }

    private func startSimulation(restart: Bool = false, target: Double = 312.4) {
        simulationTask?.cancel()
        let driver = MockFoodScaleDriver()
        simulationTask = Task { [weak self] in
            var signal = MockScaleSignal(targetGrams: target, placedAt: restart ? 0.4 : 1.5, seed: UInt64.random(in: 1...UInt64.max))
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let frame = MockFoodScaleDriver.frame(grams: signal.grams(at: t))
                if let reading = driver.parse(characteristicUUID: MockFoodScaleDriver.notifyChar, value: frame, receivedAt: Date()) {
                    self?.ingest(reading)
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 10 Hz
            }
        }
    }

    // MARK: CoreBluetooth callbacks (called on main queue via BLEProxy)

    fileprivate func centralDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: beginScanIfReady()
        case .poweredOff: state = .poweredOff
        case .unauthorized: state = .unauthorized
        case .unsupported: state = .unsupported
        default: break
        }
    }

    private func beginScanIfReady() {
        guard wantsScan, let central, central.state == .poweredOn else { return }
        state = .scanning
        // Many kitchen scales don't advertise their service UUIDs, so scan unfiltered and let drivers match.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    fileprivate func didDiscover(_ peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        let ad = ScaleAdvertisement(localName: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name,
                                    serviceUUIDs: services,
                                    manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                                    rssi: rssi.intValue)
        guard let driver = registry.driver(for: ad) else { return }
        peripherals[peripheral.identifier] = peripheral
        drivers[peripheral.identifier] = driver
        let item = DiscoveredScale(id: peripheral.identifier, name: ad.localName ?? driver.displayName, driverID: driver.id,
                                   driverName: driver.displayName, rssi: rssi.intValue)
        if let idx = discovered.firstIndex(where: { $0.id == item.id }) { discovered[idx] = item } else { discovered.append(item) }
    }

    fileprivate func didConnect(_ peripheral: CBPeripheral) {
        guard let driver = activeDriver else { return }
        peripheral.delegate = proxy
        connectedDriverName = driver.displayName
        state = .connected(peripheral.name ?? driver.displayName)
        peripheral.discoverServices(driver.serviceUUIDs.map { CBUUID(string: $0) })
    }

    fileprivate func didFailToConnect(_ peripheral: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Couldn't connect to the scale.")
    }

    fileprivate func didDisconnect(_ peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == activePeripheral?.identifier else { return }
        if let error { state = .failed(error.localizedDescription) } else { state = .idle }
        activePeripheral = nil
        latestReading = nil; stableGrams = nil
    }

    fileprivate func didDiscoverServices(_ peripheral: CBPeripheral) {
        guard activeDriver != nil else { return }
        for service in peripheral.services ?? [] {
            // Discover all characteristics: notify ones are subscribed, write ones are used for tare/unit commands.
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    fileprivate func didDiscoverCharacteristics(_ peripheral: CBPeripheral, service: CBService) {
        guard let driver = activeDriver else { return }
        for c in service.characteristics ?? [] {
            let uuid = BLEUUID.normalize(c.uuid.uuidString)
            if driver.notifyCharacteristicUUIDs.contains(where: { BLEUUID.equal($0, uuid) }),
               c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    @discardableResult
    private func write(_ command: ScaleCommand, to peripheral: CBPeripheral) -> Bool {
        for service in peripheral.services ?? [] where BLEUUID.equal(service.uuid.uuidString, command.serviceUUID) {
            for c in service.characteristics ?? [] where BLEUUID.equal(c.uuid.uuidString, command.characteristicUUID) {
                peripheral.writeValue(command.data, for: c, type: command.withResponse ? .withResponse : .withoutResponse)
                return true
            }
        }
        return false
    }
}

/// NSObject delegate that forwards CoreBluetooth callbacks (delivered on the main queue) to the manager.
private final class BLEProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: FoodScaleManager?

    init(owner: FoodScaleManager) { self.owner = owner }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { owner?.centralDidUpdateState(central) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated { owner?.didDiscover(peripheral, advertisementData: advertisementData, rssi: RSSI) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { owner?.didConnect(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.didFailToConnect(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { owner?.didDisconnect(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { owner?.didDiscoverServices(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { owner?.didDiscoverCharacteristics(peripheral, service: service) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString
        MainActor.assumeIsolated { owner?.handle(value: value, characteristicUUID: uuid) }
    }
}
#endif
