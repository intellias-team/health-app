import Foundation
import CoreModels

/// Small, dependency-free statistics helpers.
public enum Stats {
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func standardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1, let m = mean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    /// Pearson product-moment correlation. Returns nil when n < 3 or either series has zero variance.
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double? {
        let n = min(x.count, y.count)
        guard n >= 3 else { return nil }
        let xs = Array(x.prefix(n)), ys = Array(y.prefix(n))
        let mx = xs.reduce(0, +) / Double(n)
        let my = ys.reduce(0, +) / Double(n)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in 0..<n {
            let dx = xs[i] - mx, dy = ys[i] - my
            sxy += dx * dy; sxx += dx * dx; syy += dy * dy
        }
        guard sxx > 0, syy > 0 else { return nil }
        let r = sxy / (sxx * syy).squareRoot()
        return Swift.max(-1, Swift.min(1, r))
    }

    /// Trailing rolling average over a calendar window of `windowDays` (inclusive of the current day).
    /// Missing days are skipped rather than treated as zero, so sparse series (e.g. weight) are smoothed correctly.
    public static func rollingAverage(_ points: [TrendPoint], windowDays: Int) -> [TrendPoint] {
        guard windowDays > 0 else { return points }
        let sorted = points.sorted { $0.date < $1.date }
        var result: [TrendPoint] = []
        result.reserveCapacity(sorted.count)
        var windowStart = 0
        var sum = 0.0
        for (i, p) in sorted.enumerated() {
            sum += p.value
            while sorted[windowStart].date.days(to: p.date) >= windowDays {
                sum -= sorted[windowStart].value
                windowStart += 1
            }
            let count = Double(i - windowStart + 1)
            result.append(TrendPoint(date: p.date, value: sum / count))
        }
        return result
    }

    /// Least-squares slope in value units per day.
    public static func slopePerDay(_ points: [TrendPoint]) -> Double? {
        guard points.count >= 2 else { return nil }
        let base = points.map(\.date.dayNumber).min() ?? 0
        let xs = points.map { Double($0.date.dayNumber - base) }
        let ys = points.map(\.value)
        guard let mx = mean(xs), let my = mean(ys) else { return nil }
        var num = 0.0, den = 0.0
        for i in xs.indices { num += (xs[i] - mx) * (ys[i] - my); den += (xs[i] - mx) * (xs[i] - mx) }
        return den > 0 ? num / den : nil
    }

    public struct Summary: Hashable, Sendable {
        public var avg: Double?
        public var min: Double?
        public var max: Double?
        /// Last value minus first value.
        public var delta: Double?
    }

    public static func summary(_ points: [TrendPoint]) -> Summary {
        let sorted = points.sorted { $0.date < $1.date }
        let values = sorted.map(\.value)
        let delta: Double? = (sorted.count >= 2) ? sorted.last!.value - sorted.first!.value : nil
        return Summary(avg: mean(values), min: values.min(), max: values.max(), delta: delta)
    }
}
