import Foundation
import CoreModels

/// The data behind the Today screen's signature "Fuel · Train · Recover" card.
public struct DailyBalance: Hashable, Sendable {
    public struct Fuel: Hashable, Sendable {
        public var energy: EnergyBalance
        public var proteinG: Double
        public var proteinGoalG: Double
        public var mealsLogged: Int
        /// Neutral descriptor of intake relative to expenditure so far.
        public var label: String
    }

    public struct Train: Hashable, Sendable {
        public var loadToday: Double
        public var acuteChronic: TrainingLoad.AcuteChronic
        public var workoutCount: Int
        public var workoutMinutes: Double
        public var activeKcal: Double
        public var steps: Double?
        public var label: String
    }

    public struct Recover: Hashable, Sendable {
        public var readiness: Double?
        public var sleepScore: Double?
        public var sleepMinutes: Double?
        public var hrvMs: Double?
        /// 28-day average HRV for context.
        public var hrvBaselineMs: Double?
        public var restingHr: Double?
        public var label: String
    }

    public var date: LocalDate
    public var fuel: Fuel
    public var train: Train
    public var recover: Recover
    /// One neutral sentence tying the three together.
    public var headline: String
    public var fuelingInsight: FuelingInsight?
}

public enum DailyBalanceComposer {
    /// - Parameters:
    ///   - history: merged daily metrics for (at least) the previous 28 days, for baselines.
    ///   - workouts: workouts for (at least) the previous 28 days, including today.
    ///   - dayProgress: 0…1, how much of the waking day has passed (1 for past days).
    public static func compose(summary: DaySummary, history: [MergedDay], workouts: [Workout], goals: Goals,
                               dayProgress: Double, fallbackRestingKcal: Double? = nil, calendar: Calendar = .current) -> DailyBalance {
        let energy = summary.energyBalance ?? EnergyBalanceCalculator.balance(metrics: summary.metrics, meals: summary.activeMeals, fallbackRestingKcal: fallbackRestingKcal)
        let meals = summary.activeMeals

        // Fuel
        let ratio = energy.intakeRatio
        let fuelLabel: String
        if meals.isEmpty { fuelLabel = "Nothing logged yet" }
        else if ratio < 0.75 { fuelLabel = "Below energy use" }
        else if ratio <= 1.1 { fuelLabel = "Close to energy use" }
        else { fuelLabel = "Above energy use" }
        let fuel = DailyBalance.Fuel(energy: energy, proteinG: summary.totals.proteinG, proteinGoalG: goals.proteinG,
                                     mealsLogged: meals.count, label: fuelLabel)

        // Train
        let restingHr = summary.metrics.restingHr
        let loads = TrainingLoad.dailyLoads(workouts, restingHr: restingHr, calendar: calendar)
        let todays = workouts.filter { LocalDate($0.start, calendar: calendar) == summary.date }
        let loadToday = loads[summary.date] ?? 0
        let ac = TrainingLoad.acuteChronic(dailyLoads: loads, on: summary.date)
        let trainLabel: String
        switch loadToday {
        case 0: trainLabel = todays.isEmpty ? "Rest day" : "Light"
        case ..<50: trainLabel = "Light"
        case ..<120: trainLabel = "Moderate"
        default: trainLabel = "Hard"
        }
        let train = DailyBalance.Train(loadToday: loadToday, acuteChronic: ac, workoutCount: todays.count,
                                       workoutMinutes: todays.reduce(0) { $0 + $1.durationMin },
                                       activeKcal: energy.activeKcal, steps: summary.metrics.steps, label: trainLabel)

        // Recover
        let m = summary.metrics
        let start = summary.date.adding(days: -28)
        let hrvHistory = history.filter { $0.date >= start && $0.date < summary.date }.compactMap { $0.merged.hrvMs }
        let baseline = Stats.mean(hrvHistory)
        let recoverLabel: String
        if let r = m.readinessScore {
            recoverLabel = r >= 85 ? "Well recovered" : (r >= 70 ? "Steady" : "Take it easier")
        } else if let hrv = m.hrvMs, let baseline {
            recoverLabel = hrv >= baseline * 0.95 ? "Steady" : "Below your baseline"
        } else {
            recoverLabel = "No recovery data"
        }
        let recover = DailyBalance.Recover(readiness: m.readinessScore, sleepScore: m.sleepScore, sleepMinutes: m.sleepMinutes,
                                           hrvMs: m.hrvMs, hrvBaselineMs: baseline, restingHr: m.restingHr, label: recoverLabel)

        let insight = FuelingInsightEngine.evaluate(balance: energy, trainingLoad: loadToday, readiness: m.readinessScore,
                                                    dayProgress: dayProgress, mealsLogged: meals.count)
        let headline = makeHeadline(fuel: fuel, train: train, recover: recover)
        return DailyBalance(date: summary.date, fuel: fuel, train: train, recover: recover, headline: headline, fuelingInsight: insight)
    }

    static func makeHeadline(fuel: DailyBalance.Fuel, train: DailyBalance.Train, recover: DailyBalance.Recover) -> String {
        let trainPart = train.workoutCount > 0 ? "\(train.label.lowercased()) training" : "a rest day"
        let recoverPart: String
        if let r = recover.readiness { recoverPart = "readiness \(Int(r))" }
        else if let s = recover.sleepMinutes { recoverPart = "\(Units.formatDuration(minutes: s)) sleep" }
        else { recoverPart = "no recovery data yet" }
        return "\(trainPart.prefix(1).uppercased() + trainPart.dropFirst()), \(recoverPart), intake \(fuel.label.lowercased())."
    }
}
