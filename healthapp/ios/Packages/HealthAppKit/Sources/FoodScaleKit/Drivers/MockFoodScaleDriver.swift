import Foundation

/// Simulated scale for the iOS Simulator and demo mode (no Bluetooth hardware needed).
/// Frames: Float32 little-endian grams (4 bytes) + 1 byte flags (bit0 stable).
public struct MockFoodScaleDriver: FoodScaleDriver {
    public static let localName = "HealthApp Simulated Scale"
    public static let service = "FFF0"
    public static let notifyChar = "FFF1"

    public init() {}

    public var id: String { "mock-scale" }
    public var displayName: String { "Simulated food scale" }
    public var serviceUUIDs: [String] { [Self.service] }
    public var notifyCharacteristicUUIDs: [String] { [Self.notifyChar] }

    public func matchScore(for ad: ScaleAdvertisement) -> Int { ad.localName == Self.localName ? 100 : 0 }

    public func parse(characteristicUUID: String, value: Data, receivedAt: Date) -> WeightReading? {
        let b = [UInt8](value)
        guard b.count == 5 else { return nil }
        let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
        let grams = Double(Float(bitPattern: bits))
        return WeightReading(grams: grams, isStable: false, unit: .grams, timestamp: receivedAt)
    }

    public func tareCommand() -> ScaleCommand? {
        ScaleCommand(serviceUUID: Self.service, characteristicUUID: "FFF2", data: Data([0x01]))
    }

    public static func frame(grams: Double) -> Data {
        let bits = Float(grams).bitPattern
        return Data([UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF), 0])
    }
}

/// Generates a realistic weight signal: empty platform → item placed (overshoot + settle with noise) → hold.
public struct MockScaleSignal: Sendable {
    public var targetGrams: Double
    public var placedAt: TimeInterval
    public var noise: Double
    private var rng: SplitMix64

    public init(targetGrams: Double = 312.4, placedAt: TimeInterval = 1.5, noise: Double = 0.3, seed: UInt64 = 42) {
        self.targetGrams = targetGrams; self.placedAt = placedAt; self.noise = noise
        self.rng = SplitMix64(seed: seed)
    }

    /// Weight at `t` seconds since start.
    public mutating func grams(at t: TimeInterval) -> Double {
        guard t >= placedAt else { return jitter() * 0.2 }
        let dt = t - placedAt
        // Damped oscillation toward target over ~1 s.
        let settle = targetGrams * (1 - exp(-6 * dt) * cos(9 * dt))
        let n = dt > 1.2 ? jitter() * 0.5 : jitter() * 3
        return max(0, settle + n)
    }

    private mutating func jitter() -> Double {
        (Double(rng.next() % 10_000) / 10_000 - 0.5) * 2 * noise
    }
}

/// Tiny deterministic PRNG (Foundation-only, Sendable).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
