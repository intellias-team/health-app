import Foundation
import CoreModels

/// Compare two metrics (Trends → Compare).
public enum CorrelationAnalyzer {
    public static let caveat = "Correlation is not causation. A relationship between two metrics doesn't mean one causes the other — other factors (stress, illness, schedule, data gaps) can drive both."

    /// Pairs x on day d with y on day d + lagDays (e.g. lag 1: "protein today vs readiness tomorrow").
    public static func pairs(x: [TrendPoint], y: [TrendPoint], lagDays: Int = 0) -> [ComparePair] {
        var yByDate: [LocalDate: Double] = [:]
        for p in y { yByDate[p.date] = p.value }
        return x.sorted { $0.date < $1.date }.compactMap { px in
            guard let vy = yByDate[px.date.adding(days: lagDays)] else { return nil }
            return ComparePair(date: px.date, x: px.value, y: vy)
        }
    }

    public static func compare(xMetric: TrendMetric, yMetric: TrendMetric, x: [TrendPoint], y: [TrendPoint], lagDays: Int = 0) -> CompareResult {
        let p = pairs(x: x, y: y, lagDays: lagDays)
        let r = Stats.pearson(p.map(\.x), p.map(\.y))
        return CompareResult(x: xMetric, y: yMetric, pairs: p, pearsonR: r, n: p.count, caveat: caveat)
    }

    /// Plain-language description of r, e.g. "Moderate positive relationship".
    public static func describe(r: Double?, n: Int) -> String {
        guard let r, n >= 7 else { return "Not enough paired days yet to describe a relationship." }
        let strength: String
        switch abs(r) {
        case ..<0.1: return "No clear relationship"
        case ..<0.3: strength = "Weak"
        case ..<0.5: strength = "Moderate"
        default: strength = "Strong"
        }
        return "\(strength) \(r > 0 ? "positive" : "negative") relationship"
    }
}
