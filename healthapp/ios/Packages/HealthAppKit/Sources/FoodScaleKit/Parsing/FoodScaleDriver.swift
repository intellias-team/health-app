import Foundation

/// What a scale advertises (copied out of CoreBluetooth's advertisement dictionary so drivers stay Foundation-only).
public struct ScaleAdvertisement: Hashable, Sendable {
    public var localName: String?
    /// Normalised service UUID strings (see `BLEUUID.normalize`).
    public var serviceUUIDs: [String]
    public var manufacturerData: Data?
    public var rssi: Int?

    public init(localName: String?, serviceUUIDs: [String] = [], manufacturerData: Data? = nil, rssi: Int? = nil) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs.map(BLEUUID.normalize)
        self.manufacturerData = manufacturerData
        self.rssi = rssi
    }

    /// Bluetooth company identifier (first two bytes of manufacturer data, little-endian).
    public var companyIdentifier: UInt16? {
        guard let d = manufacturerData, d.count >= 2 else { return nil }
        let b = [UInt8](d.prefix(2))
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
}

/// A write the manager should perform on behalf of a driver (tare, unit change…).
public struct ScaleCommand: Hashable, Sendable {
    public var serviceUUID: String
    public var characteristicUUID: String
    public var data: Data
    public var withResponse: Bool
    public init(serviceUUID: String, characteristicUUID: String, data: Data, withResponse: Bool = false) {
        self.serviceUUID = BLEUUID.normalize(serviceUUID); self.characteristicUUID = BLEUUID.normalize(characteristicUUID)
        self.data = data; self.withResponse = withResponse
    }
}

/// Implement this to support a new Bluetooth food scale. See README → "Adding a food-scale driver".
///
/// Drivers are pure value types: they identify a scale from its advertisement, list the GATT services and
/// characteristics to subscribe to, turn notification bytes into `WeightReading`s and optionally produce
/// command bytes. All Bluetooth I/O is done by `FoodScaleManager`.
public protocol FoodScaleDriver: Sendable {
    /// Stable identifier, e.g. "sig-weight-scale" — persisted with paired devices.
    var id: String { get }
    var displayName: String { get }
    /// Services to discover after connecting (normalised UUID strings).
    var serviceUUIDs: [String] { get }
    /// Characteristics to subscribe to (notify or indicate).
    var notifyCharacteristicUUIDs: [String] { get }
    /// 0 = not this driver's scale; higher = more specific match. The registry picks the highest score.
    func matchScore(for advertisement: ScaleAdvertisement) -> Int
    /// Parses one notification value. Return nil for frames that aren't weight readings.
    func parse(characteristicUUID: String, value: Data, receivedAt: Date) -> WeightReading?
    /// Command that zeroes the scale, or nil if unsupported (the manager then tares in software).
    func tareCommand() -> ScaleCommand?
    /// Command to switch the display unit, or nil if unsupported.
    func unitCommand(_ unit: WeightUnit) -> ScaleCommand?
}

public extension FoodScaleDriver {
    func tareCommand() -> ScaleCommand? { nil }
    func unitCommand(_ unit: WeightUnit) -> ScaleCommand? { nil }
}

/// Pluggable set of drivers. Order only matters for equal match scores.
public struct FoodScaleRegistry: Sendable {
    public private(set) var drivers: [any FoodScaleDriver]

    public init(drivers: [any FoodScaleDriver]) { self.drivers = drivers }

    /// The default registry shipped with the app. Add new drivers here.
    public static let standard = FoodScaleRegistry(drivers: [
        ExampleVendorScaleDriver(),
        StandardWeightScaleDriver(),
    ])

    /// Registry used in the Simulator / demo mode.
    public static let simulator = FoodScaleRegistry(drivers: [MockFoodScaleDriver()])

    public mutating func register(_ driver: any FoodScaleDriver) {
        drivers.removeAll { $0.id == driver.id }
        drivers.append(driver)
    }

    /// Best matching driver for an advertisement, or nil.
    public func driver(for advertisement: ScaleAdvertisement) -> (any FoodScaleDriver)? {
        var best: (any FoodScaleDriver)?
        var bestScore = 0
        for d in drivers {
            let s = d.matchScore(for: advertisement)
            if s > bestScore { best = d; bestScore = s }
        }
        return best
    }

    public func driver(id: String) -> (any FoodScaleDriver)? { drivers.first { $0.id == id } }

    /// Union of all services (useful when a platform requires filtered scans in background).
    public var allServiceUUIDs: [String] { Array(Set(drivers.flatMap(\.serviceUUIDs))).sorted() }
}
