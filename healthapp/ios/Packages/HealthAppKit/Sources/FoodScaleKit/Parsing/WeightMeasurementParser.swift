import Foundation

/// Decoded Bluetooth SIG Weight Measurement characteristic (0x2A9D), per the Weight Scale Service spec.
public struct WeightMeasurement: Hashable, Sendable {
    public var weightKg: Double
    public var isImperial: Bool
    public var timestamp: DateComponents?
    public var userId: UInt8?
    public var bmi: Double?
    /// Height in metres (converted from inches when imperial).
    public var heightM: Double?

    public var grams: Double { weightKg * 1000 }
}

public enum WeightMeasurementParser {
    /// Flags (uint8):
    /// - bit 0: 0 = SI (weight resolution 0.005 kg, height 0.001 m); 1 = Imperial (0.01 lb, height 0.1 in)
    /// - bit 1: Time Stamp present (7 bytes: year u16, month, day, hours, minutes, seconds)
    /// - bit 2: User ID present (u8)
    /// - bit 3: BMI (u16, 0.1) and Height (u16) present
    /// Weight is u16 little-endian; 0xFFFF means "measurement unsuccessful".
    public static func parse(_ data: Data) -> WeightMeasurement? {
        var r = ByteReader(data)
        guard let flags = r.uint8(), let rawWeight = r.uint16() else { return nil }
        guard rawWeight != 0xFFFF else { return nil }
        let imperial = flags & 0x01 != 0
        let weightKg: Double = imperial ? Double(rawWeight) * 0.01 * 0.45359237 : Double(rawWeight) * 0.005

        var ts: DateComponents?
        if flags & 0x02 != 0 {
            guard let year = r.uint16(), let month = r.uint8(), let day = r.uint8(),
                  let h = r.uint8(), let m = r.uint8(), let s = r.uint8() else { return nil }
            var c = DateComponents()
            c.year = Int(year); c.month = Int(month); c.day = Int(day)
            c.hour = Int(h); c.minute = Int(m); c.second = Int(s)
            ts = c
        }
        var userId: UInt8?
        if flags & 0x04 != 0 {
            guard let u = r.uint8() else { return nil }
            userId = u == 0xFF ? nil : u // 0xFF = unknown user
        }
        var bmi: Double?, height: Double?
        if flags & 0x08 != 0 {
            guard let b = r.uint16(), let hgt = r.uint16() else { return nil }
            bmi = Double(b) * 0.1
            height = imperial ? Double(hgt) * 0.1 * 0.0254 : Double(hgt) * 0.001
        }
        return WeightMeasurement(weightKg: weightKg, isImperial: imperial, timestamp: ts, userId: userId, bmi: bmi, heightM: height)
    }

    /// Encodes a measurement (used by tests and the simulator).
    public static func encode(weightKg: Double, imperial: Bool = false) -> Data {
        let raw: UInt16 = imperial
            ? UInt16((weightKg / 0.45359237 / 0.01).rounded())
            : UInt16((weightKg / 0.005).rounded())
        return Data([imperial ? 0x01 : 0x00, UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }
}
