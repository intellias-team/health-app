import Foundation

/// Unit the scale is displaying. Readings are always normalised to grams.
public enum WeightUnit: String, Codable, Hashable, Sendable, CaseIterable {
    case grams, kilograms, pounds, ounces, milliliters
}

/// One weight sample from a food scale.
public struct WeightReading: Hashable, Sendable {
    /// Net weight in grams (after any tare applied by the scale).
    public var grams: Double
    /// True if the *scale itself* flagged the reading as stable. Drivers that can't tell set false and
    /// rely on `StableWeightDetector`.
    public var isStable: Bool
    public var unit: WeightUnit
    public var timestamp: Date

    public init(grams: Double, isStable: Bool = false, unit: WeightUnit = .grams, timestamp: Date = Date()) {
        self.grams = grams; self.isStable = isStable; self.unit = unit; self.timestamp = timestamp
    }
}

/// Bluetooth UUID helpers that work with plain strings (no CoreBluetooth dependency).
public enum BLEUUID {
    static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    /// Upper-cases and shortens SIG-base 128-bit UUIDs to their 16-bit form ("00002A9D-0000-1000-8000-00805F9B34FB" → "2A9D").
    public static func normalize(_ uuid: String) -> String {
        let u = uuid.uppercased()
        if u.count == 36, u.hasSuffix(baseSuffix), u.hasPrefix("0000") {
            return String(u.dropFirst(4).prefix(4))
        }
        return u
    }

    public static func equal(_ a: String, _ b: String) -> Bool { normalize(a) == normalize(b) }

    // Bluetooth SIG assigned numbers used by the drivers.
    public static let weightScaleService = "181D"
    public static let weightMeasurement = "2A9D"
    public static let weightScaleFeature = "2A9E"
    public static let bodyCompositionService = "181B"
    public static let bodyCompositionMeasurement = "2A9C"
}

/// Little-endian byte reader with bounds checking.
public struct ByteReader {
    private let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.bytes = [UInt8](data) }

    public var remaining: Int { bytes.count - offset }

    public mutating func uint8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func uint16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    public mutating func int24() -> Int32? {
        guard remaining >= 3 else { return nil }
        defer { offset += 3 }
        var v = Int32(bytes[offset]) | (Int32(bytes[offset + 1]) << 8) | (Int32(bytes[offset + 2]) << 16)
        if v & 0x80_0000 != 0 { v |= Int32(bitPattern: 0xFF00_0000) } // sign-extend
        return v
    }

    public mutating func skip(_ n: Int) -> Bool {
        guard remaining >= n else { return false }
        offset += n
        return true
    }
}
