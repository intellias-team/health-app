import Foundation
import CoreModels

public enum EnergyBalanceCalculator {
    /// Builds the day's energy balance keeping resting, active, total and intake separate.
    /// - Parameter fallbackRestingKcal: used when no source reported resting energy (e.g. Mifflin-St Jeor × day fraction).
    public static func balance(metrics: MetricValues, meals: [Meal], fallbackRestingKcal: Double? = nil) -> EnergyBalance {
        let active = metrics.activeKcal ?? 0
        let live = meals.filter { !$0.deleted }
        let intake = live.reduce(0) { $0 + $1.totals.kcal }
        let intakeIsEstimate = live.contains { $0.isEstimate }
        if let resting = metrics.restingKcal {
            return EnergyBalance(restingKcal: resting, activeKcal: active, intakeKcal: intake, intakeIsEstimate: intakeIsEstimate)
        }
        return EnergyBalance(restingKcal: fallbackRestingKcal ?? 0, activeKcal: active, intakeKcal: intake,
                             intakeIsEstimate: intakeIsEstimate, restingIsEstimated: fallbackRestingKcal != nil)
    }

    /// Mifflin-St Jeor resting metabolic rate (kcal/day).
    public static func mifflinStJeor(weightKg: Double, heightCm: Double, age: Int, sex: BiologicalSex?) -> Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        default: return base - 78 // midpoint when unspecified
        }
    }

    /// Fraction of the local day elapsed at `date` (used to pro-rate an estimated resting energy for "today").
    public static func dayFraction(at date: Date, calendar: Calendar = .current) -> Double {
        let start = calendar.startOfDay(for: date)
        return min(1, max(0, date.timeIntervalSince(start) / 86_400))
    }
}

/// A neutral recovery-and-fueling message. Wording rules (enforced by tests):
/// never praise a deficit, never moralise food, no "good/bad", always invite rather than instruct.
public struct FuelingInsight: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable { case lowIntakeHighActivity, lowIntakeLowRecovery }
    public var kind: Kind
    public var title: String
    public var message: String

    public var asInsight: Insight { Insight(id: "fueling-\(kind.rawValue)", kind: "fueling", title: title, message: message, tone: .neutral) }
}

public enum FuelingInsightEngine {
    /// Words that must never appear in fueling copy (checked in unit tests).
    public static let forbiddenWords = ["great", "good job", "well done", "nice", "awesome", "congrat", "keep it up",
                                        "excellent", "perfect", "deficit", "on track", "proud", "win", "bad", "cheat", "guilt", "burn it off", "earned"]

    /// Returns a message when logged intake is unusually low relative to expenditure/activity.
    /// - Parameters:
    ///   - dayProgress: 0…1 fraction of the waking day elapsed; early in the day low intake is expected, so we stay quiet.
    ///   - trainingLoad: today's training load (TRIMP).
    public static func evaluate(balance: EnergyBalance, trainingLoad: Double, readiness: Double?, dayProgress: Double, mealsLogged: Int) -> FuelingInsight? {
        guard dayProgress >= 0.6, balance.totalExpenditureKcal > 0 else { return nil }
        let active = balance.activeKcal >= 500 || trainingLoad >= 80
        let lowIntake = balance.intakeRatio < 0.6
        guard lowIntake else { return nil }
        let unlogged = mealsLogged <= 1 ? " If some meals aren't logged yet, you can add them anytime." : ""
        if active {
            var message = "Today's activity was high compared with the food you've logged. Eating enough — including carbohydrates and protein — helps your body recover and prepares you for tomorrow."
            if let readiness, readiness < 70 {
                message += " Your readiness is also lower today, so regular meals and rest may help."
            }
            return FuelingInsight(kind: .lowIntakeHighActivity, title: "Recovery & fueling", message: message + unlogged)
        }
        if let readiness, readiness < 65 {
            return FuelingInsight(kind: .lowIntakeLowRecovery, title: "Recovery & fueling",
                                  message: "Your logged intake is lower than your energy use today and readiness is down. Regular meals and rest can support recovery." + unlogged)
        }
        return nil
    }

    /// True if `text` contains any forbidden praise/moralising word (case-insensitive).
    public static func containsForbiddenWording(_ text: String) -> Bool {
        let lower = text.lowercased()
        return forbiddenWords.contains { word in
            // whole-word match for short words like "win"/"bad"
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + (word == "congrat" ? "" : "\\b")
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
