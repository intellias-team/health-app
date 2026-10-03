import Foundation

/// TEMPLATE — copy this file to add a vendor-specific food scale.
///
/// It implements a fictional "ACME Kitchen Scale" protocol so you can see every hook end to end:
///
/// * **Identification**: local name prefix `ACME-KS` *or* manufacturer company id `0xFFFF`
///   (the Bluetooth SIG "test/reserved" id — replace with the vendor's real company id).
/// * **GATT**: custom service `FFE0`, notify characteristic `FFE1`, write characteristic `FFE2`.
/// * **Frame** (notify, 7 bytes):
///   `[0] 0xAC` header · `[1]` flags (bit0 stable, bit1 negative) · `[2..4]` uint24 LE weight in 0.1 g ·
///   `[5]` unit (0 g, 1 oz, 2 lb, 3 ml) · `[6]` XOR checksum of bytes 0…5
/// * **Commands** (write without response): tare `AC 01 00 xx`, unit `AC 02 <unit> xx` (xx = XOR of previous bytes).
///
/// To support a real scale: get the protocol from the vendor (or their SDK docs), change the UUIDs,
/// identification and frame layout, add unit tests with captured frames, then register the driver in
/// `FoodScaleRegistry.standard`. See ios/README.md → "Adding a food-scale driver".
public struct ExampleVendorScaleDriver: FoodScaleDriver {
    public init() {}

    static let service = "FFE0"
    static let notifyChar = "FFE1"
    static let writeChar = "FFE2"
    static let header: UInt8 = 0xAC
    static let companyId: UInt16 = 0xFFFF

    public var id: String { "example-acme-kitchen" }
    public var displayName: String { "ACME Kitchen Scale (example)" }
    public var serviceUUIDs: [String] { [Self.service] }
    public var notifyCharacteristicUUIDs: [String] { [Self.notifyChar] }

    public func matchScore(for ad: ScaleAdvertisement) -> Int {
        if let name = ad.localName, name.uppercased().hasPrefix("ACME-KS") { return 50 }
        if ad.companyIdentifier == Self.companyId && ad.serviceUUIDs.contains(Self.service) { return 40 }
        return 0
    }

    public func parse(characteristicUUID: String, value: Data, receivedAt: Date) -> WeightReading? {
        guard BLEUUID.equal(characteristicUUID, Self.notifyChar) else { return nil }
        let b = [UInt8](value)
        guard b.count == 7, b[0] == Self.header else { return nil }
        guard b[0..<6].reduce(0, ^) == b[6] else { return nil } // checksum
        let flags = b[1]
        let raw = Int(b[2]) | (Int(b[3]) << 8) | (Int(b[4]) << 16)
        var grams = Double(raw) / 10
        if flags & 0x02 != 0 { grams = -grams }
        let unit: WeightUnit
        switch b[5] {
        case 1: unit = .ounces
        case 2: unit = .pounds
        case 3: unit = .milliliters
        default: unit = .grams
        }
        return WeightReading(grams: grams, isStable: flags & 0x01 != 0, unit: unit, timestamp: receivedAt)
    }

    public func tareCommand() -> ScaleCommand? {
        ScaleCommand(serviceUUID: Self.service, characteristicUUID: Self.writeChar, data: Self.frame([Self.header, 0x01, 0x00]))
    }

    public func unitCommand(_ unit: WeightUnit) -> ScaleCommand? {
        let code: UInt8
        switch unit {
        case .grams: code = 0
        case .ounces: code = 1
        case .pounds: code = 2
        case .milliliters: code = 3
        case .kilograms: return nil
        }
        return ScaleCommand(serviceUUID: Self.service, characteristicUUID: Self.writeChar, data: Self.frame([Self.header, 0x02, code]))
    }

    /// Appends the XOR checksum.
    static func frame(_ bytes: [UInt8]) -> Data { Data(bytes + [bytes.reduce(0, ^)]) }

    /// Builds a notify frame (for tests / simulator).
    public static func makeWeightFrame(grams: Double, stable: Bool, unit: UInt8 = 0) -> Data {
        let raw = Int((abs(grams) * 10).rounded())
        var flags: UInt8 = stable ? 0x01 : 0
        if grams < 0 { flags |= 0x02 }
        let bytes: [UInt8] = [header, flags, UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8((raw >> 16) & 0xFF), unit]
        return frame(bytes)
    }
}
