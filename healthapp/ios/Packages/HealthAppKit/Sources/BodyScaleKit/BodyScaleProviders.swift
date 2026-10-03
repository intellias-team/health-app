import Foundation
import CoreModels
import FoodScaleKit

/// Reads body measurements written to Apple Health by *any* smart-scale app (Withings, Eufy, Renpho…).
/// This is the MVP path: no vendor SDKs, works with every scale whose app syncs to Health.
public struct HealthKitBodyScaleProvider: BodyScaleProvider {
    private let health: HealthDataSource
    public init(health: HealthDataSource) { self.health = health }
    public var id: String { "bodyscale:healthkit" }
    public var displayName: String { "Smart scale via Apple Health" }

    public func measurements(since: Date) async throws -> [BodyMeasurement] {
        try await health.bodyMeasurements(from: LocalDate(since), to: .today()).filter { $0.measuredAt >= since }
    }
}

/// Decoded Bluetooth SIG Body Composition Measurement (0x2A9C).
public struct BodyCompositionMeasurement: Hashable, Sendable {
    public var bodyFatPct: Double
    public var isImperial: Bool
    public var timestamp: DateComponents?
    public var userId: UInt8?
    public var basalMetabolismKJ: Double?
    public var musclePct: Double?
    public var muscleMassKg: Double?
    public var fatFreeMassKg: Double?
    public var softLeanMassKg: Double?
    public var bodyWaterMassKg: Double?
    public var impedanceOhm: Double?
    public var weightKg: Double?
    public var heightM: Double?
    public var isMultiPacket: Bool

    /// Maps to the app's model. Body-water mass is converted to a percentage when weight is known.
    public func asBodyMeasurement(id: String = UUID().uuidString.lowercased(), at date: Date, source: String) -> BodyMeasurement {
        var water: Double?
        if let w = bodyWaterMassKg, let kg = weightKg, kg > 0 { water = w / kg * 100 }
        return BodyMeasurement(id: id, measuredAt: date, source: source, weightKg: weightKg, bodyFatPct: bodyFatPct,
                               muscleMassKg: muscleMassKg, leanMassKg: fatFreeMassKg, waterPct: water,
                               bmrKcal: basalMetabolismKJ.map { $0 / 4.184 })
    }
}

public enum BodyCompositionParser {
    /// Flags (uint16): bit0 imperial, bit1 timestamp, bit2 user id, bit3 basal metabolism, bit4 muscle %,
    /// bit5 muscle mass, bit6 fat-free mass, bit7 soft lean mass, bit8 body water mass, bit9 impedance,
    /// bit10 weight, bit11 height, bit12 multiple packet. Body fat % (uint16, 0.1 %) is mandatory.
    public static func parse(_ data: Data) -> BodyCompositionMeasurement? {
        var r = ByteReader(data)
        guard let flags = r.uint16(), let fat = r.uint16() else { return nil }
        let imperial = flags & 0x0001 != 0
        func mass(_ raw: UInt16) -> Double { imperial ? Double(raw) * 0.01 * 0.45359237 : Double(raw) * 0.005 }
        var m = BodyCompositionMeasurement(bodyFatPct: Double(fat) * 0.1, isImperial: imperial, isMultiPacket: flags & 0x1000 != 0)
        if flags & 0x0002 != 0 {
            guard let y = r.uint16(), let mo = r.uint8(), let d = r.uint8(), let h = r.uint8(), let mi = r.uint8(), let s = r.uint8() else { return nil }
            var c = DateComponents()
            c.year = Int(y); c.month = Int(mo); c.day = Int(d); c.hour = Int(h); c.minute = Int(mi); c.second = Int(s)
            m.timestamp = c
        }
        if flags & 0x0004 != 0 { guard let u = r.uint8() else { return nil }; m.userId = u == 0xFF ? nil : u }
        if flags & 0x0008 != 0 { guard let v = r.uint16() else { return nil }; m.basalMetabolismKJ = Double(v) }
        if flags & 0x0010 != 0 { guard let v = r.uint16() else { return nil }; m.musclePct = Double(v) * 0.1 }
        if flags & 0x0020 != 0 { guard let v = r.uint16() else { return nil }; m.muscleMassKg = mass(v) }
        if flags & 0x0040 != 0 { guard let v = r.uint16() else { return nil }; m.fatFreeMassKg = mass(v) }
        if flags & 0x0080 != 0 { guard let v = r.uint16() else { return nil }; m.softLeanMassKg = mass(v) }
        if flags & 0x0100 != 0 { guard let v = r.uint16() else { return nil }; m.bodyWaterMassKg = mass(v) }
        if flags & 0x0200 != 0 { guard let v = r.uint16() else { return nil }; m.impedanceOhm = Double(v) * 0.1 }
        if flags & 0x0400 != 0 { guard let v = r.uint16() else { return nil }; m.weightKg = mass(v) }
        if flags & 0x0800 != 0 { guard let v = r.uint16() else { return nil }; m.heightM = imperial ? Double(v) * 0.1 * 0.0254 : Double(v) * 0.001 }
        return m
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth

/// Direct BLE integration with scales implementing the Weight Scale (0x181D) and Body Composition (0x181B)
/// services. Not used in the MVP (the HealthKit path covers most scales); kept as the integration point.
///
/// Most body scales only send measurements for a registered user (User Data Service 0x181C + consent code),
/// which this skeleton does not implement yet.
public final class BLEBodyCompositionProvider: NSObject, BodyScaleProvider, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public var id: String { "bodyscale:ble" }
    public var displayName: String { "Bluetooth body scale" }

    private var central: CBCentralManager?
    private var received: [BodyMeasurement] = []
    private var pendingWeight: WeightMeasurement?
    private let lock = NSLock()

    public override init() { super.init() }

    public func start() {
        central = CBCentralManager(delegate: self, queue: DispatchQueue(label: "healthapp.bodyscale"))
    }

    public func measurements(since: Date) async throws -> [BodyMeasurement] {
        lock.withLock { received.filter { $0.measuredAt >= since } }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [CBUUID(string: BLEUUID.weightScaleService), CBUUID(string: BLEUUID.bodyCompositionService)])
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        central.stopScan()
        peripheral.delegate = self
        central.connect(peripheral)
        lock.lock(); retained = peripheral; lock.unlock()
    }

    private var retained: CBPeripheral?

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([CBUUID(string: BLEUUID.weightScaleService), CBUUID(string: BLEUUID.bodyCompositionService)])
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        for s in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] where c.properties.contains(.indicate) || c.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: c)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value else { return }
        let uuid = BLEUUID.normalize(characteristic.uuid.uuidString)
        lock.lock(); defer { lock.unlock() }
        if uuid == BLEUUID.weightMeasurement, let w = WeightMeasurementParser.parse(value) {
            pendingWeight = w
            received.append(BodyMeasurement(measuredAt: Date(), source: id, weightKg: w.weightKg, bmi: w.bmi))
        } else if uuid == BLEUUID.bodyCompositionMeasurement, var m = BodyCompositionParser.parse(value) {
            if m.weightKg == nil { m.weightKg = pendingWeight?.weightKg }
            received.append(m.asBodyMeasurement(at: Date(), source: id))
        }
    }
}
#endif
