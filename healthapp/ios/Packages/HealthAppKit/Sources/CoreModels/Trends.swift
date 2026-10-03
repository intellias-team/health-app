import Foundation

/// Trend metric ids (docs/03 §3.3 "Trend metric ids").
public enum TrendMetric: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case weight, bodyFatPct, muscleMassKg, kcalIn, proteinG, carbsG, fatG, fiberG
    case sleepScore, sleepMinutes, hrvMs, restingHr, readinessScore, activityScore
    case steps, activeKcal, workoutMinutes, trainingLoad, cycleDay

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weight: return "Weight"
        case .bodyFatPct: return "Body fat"
        case .muscleMassKg: return "Muscle mass"
        case .kcalIn: return "Calories eaten"
        case .proteinG: return "Protein"
        case .carbsG: return "Carbs"
        case .fatG: return "Fat"
        case .fiberG: return "Fiber"
        case .sleepScore: return "Sleep score"
        case .sleepMinutes: return "Sleep duration"
        case .hrvMs: return "HRV"
        case .restingHr: return "Resting HR"
        case .readinessScore: return "Readiness"
        case .activityScore: return "Activity score"
        case .steps: return "Steps"
        case .activeKcal: return "Active energy"
        case .workoutMinutes: return "Workout minutes"
        case .trainingLoad: return "Training load"
        case .cycleDay: return "Cycle day"
        }
    }

    public var unit: String {
        switch self {
        case .weight, .muscleMassKg: return "kg"
        case .bodyFatPct: return "%"
        case .kcalIn, .activeKcal: return "kcal"
        case .proteinG, .carbsG, .fatG, .fiberG: return "g"
        case .sleepScore, .readinessScore, .activityScore: return "score"
        case .sleepMinutes, .workoutMinutes: return "min"
        case .hrvMs: return "ms"
        case .restingHr: return "bpm"
        case .steps: return "steps"
        case .trainingLoad: return "TRIMP"
        case .cycleDay: return "day"
        }
    }

    public enum Group: String, CaseIterable, Sendable { case body = "Body", nutrition = "Nutrition", recovery = "Recovery", activity = "Activity", cycle = "Cycle" }

    public var group: Group {
        switch self {
        case .weight, .bodyFatPct, .muscleMassKg: return .body
        case .kcalIn, .proteinG, .carbsG, .fatG, .fiberG: return .nutrition
        case .sleepScore, .sleepMinutes, .hrvMs, .restingHr, .readinessScore: return .recovery
        case .activityScore, .steps, .activeKcal, .workoutMinutes, .trainingLoad: return .activity
        case .cycleDay: return .cycle
        }
    }

    /// Whether the value is summed (weekly aggregation sums) or averaged.
    public var isCumulative: Bool {
        switch self {
        case .steps, .activeKcal, .workoutMinutes, .trainingLoad, .kcalIn, .proteinG, .carbsG, .fatG, .fiberG: return true
        default: return false
        }
    }
}

public enum TrendRange: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case week = "7d", month = "30d", quarter = "90d", year = "1y"
    public var id: String { rawValue }
    public var days: Int {
        switch self { case .week: return 7; case .month: return 30; case .quarter: return 90; case .year: return 365 }
    }
    public var label: String {
        switch self { case .week: return "7D"; case .month: return "30D"; case .quarter: return "90D"; case .year: return "1Y" }
    }
    /// Server-side aggregation that keeps charts readable.
    public var suggestedAggregation: TrendAggregation { self == .year ? .week : .day }
}

public enum TrendAggregation: String, Codable, Hashable, Sendable { case day, week }

public struct TrendPoint: Codable, Hashable, Sendable, Identifiable {
    public var date: LocalDate
    public var value: Double
    public var id: LocalDate { date }
    public init(date: LocalDate, value: Double) { self.date = date; self.value = value }
}

/// `GET /v1/trends/{metric}` response.
public struct TrendSeries: Codable, Hashable, Sendable {
    public var metric: TrendMetric
    public var unit: String
    public var points: [TrendPoint]
    public var avg: Double?
    public var min: Double?
    public var max: Double?
    public var delta: Double?

    public init(metric: TrendMetric, unit: String? = nil, points: [TrendPoint], avg: Double? = nil, min: Double? = nil, max: Double? = nil, delta: Double? = nil) {
        self.metric = metric; self.unit = unit ?? metric.unit; self.points = points
        self.avg = avg; self.min = min; self.max = max; self.delta = delta
    }
}

public struct ComparePair: Codable, Hashable, Sendable, Identifiable {
    public var date: LocalDate
    public var x: Double
    public var y: Double
    public var id: LocalDate { date }
    public init(date: LocalDate, x: Double, y: Double) { self.date = date; self.x = x; self.y = y }
}

/// `GET /v1/trends/compare` response.
public struct CompareResult: Codable, Hashable, Sendable {
    public var x: TrendMetric
    public var y: TrendMetric
    public var pairs: [ComparePair]
    public var pearsonR: Double?
    public var n: Int
    public var caveat: String
    public init(x: TrendMetric, y: TrendMetric, pairs: [ComparePair], pearsonR: Double?, n: Int, caveat: String) {
        self.x = x; self.y = y; self.pairs = pairs; self.pearsonR = pearsonR; self.n = n; self.caveat = caveat
    }
}

/// Preset comparisons offered in Trends → Compare.
public struct ComparePreset: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var x: TrendMetric
    public var y: TrendMetric
    public var lagDays: Int
    public var requiresCycleTracking: Bool

    public init(id: String, title: String, x: TrendMetric, y: TrendMetric, lagDays: Int = 0, requiresCycleTracking: Bool = false) {
        self.id = id; self.title = title; self.x = x; self.y = y; self.lagDays = lagDays; self.requiresCycleTracking = requiresCycleTracking
    }

    public static let all: [ComparePreset] = [
        ComparePreset(id: "sleep-workout", title: "Sleep vs workout performance", x: .sleepScore, y: .trainingLoad, lagDays: 1),
        ComparePreset(id: "protein-recovery", title: "Protein vs recovery", x: .proteinG, y: .readinessScore, lagDays: 1),
        ComparePreset(id: "calories-weight", title: "Calories vs weight trend", x: .kcalIn, y: .weight, lagDays: 1),
        ComparePreset(id: "hrv-load", title: "HRV vs training load", x: .trainingLoad, y: .hrvMs, lagDays: 1),
        ComparePreset(id: "weight-cycle", title: "Weight vs cycle day", x: .cycleDay, y: .weight, requiresCycleTracking: true),
    ]
}
