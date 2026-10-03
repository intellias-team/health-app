import Foundation

/// Detects when a weight has settled: at least `minReadings` samples spanning ≥ `window × minSpanFraction`
/// seconds within the last `window` seconds, all within ±`tolerance` grams of their mean.
///
/// Defaults: ±1 g over 1.0 s with ≥ 4 readings (typical scales notify at 5–10 Hz).
public struct StableWeightDetector: Sendable {
    public var tolerance: Double
    public var window: TimeInterval
    public var minReadings: Int
    public var minSpanFraction: Double
    /// Weights at or below this are treated as "empty platform" and never reported as stable.
    public var minimumGrams: Double

    private var samples: [(time: Date, grams: Double)] = []
    /// The last value reported as stable, so the same plateau isn't reported repeatedly.
    public private(set) var lastStableGrams: Double?

    public init(tolerance: Double = 1.0, window: TimeInterval = 1.0, minReadings: Int = 4, minSpanFraction: Double = 0.75, minimumGrams: Double = 0.5) {
        self.tolerance = tolerance; self.window = window; self.minReadings = minReadings
        self.minSpanFraction = minSpanFraction; self.minimumGrams = minimumGrams
    }

    /// Adds a sample. Returns the stable weight (mean of the window, rounded to 0.1 g) when the plateau is first detected.
    @discardableResult
    public mutating func add(grams: Double, at time: Date) -> Double? {
        samples.append((time, grams))
        samples.removeAll { time.timeIntervalSince($0.time) > window + 1e-9 }
        guard let stable = currentStableValue() else {
            // Movement beyond tolerance clears the latch so a new plateau can be reported.
            if let last = lastStableGrams, abs(grams - last) > tolerance { lastStableGrams = nil }
            return nil
        }
        if let last = lastStableGrams, abs(stable - last) <= tolerance { return nil }
        lastStableGrams = stable
        return stable
    }

    /// Stable value if the current window qualifies (without latching).
    public func currentStableValue() -> Double? {
        guard samples.count >= minReadings, let first = samples.first, let last = samples.last else { return nil }
        guard last.time.timeIntervalSince(first.time) >= window * minSpanFraction else { return nil }
        let values = samples.map(\.grams)
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > minimumGrams else { return nil }
        guard values.allSatisfy({ abs($0 - mean) <= tolerance }) else { return nil }
        return (mean * 10).rounded() / 10
    }

    public var isStable: Bool { currentStableValue() != nil }

    public mutating func reset() {
        samples.removeAll()
        lastStableGrams = nil
    }
}
