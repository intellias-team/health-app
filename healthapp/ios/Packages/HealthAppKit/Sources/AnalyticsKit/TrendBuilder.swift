import Foundation
import CoreModels

/// Builds `TrendSeries` from raw local data. Used by the demo repository and as an offline fallback
/// for `GET /v1/trends/{metric}` in live mode.
public struct TrendInputs: Sendable {
    public var days: [MergedDay]
    public var meals: [Meal]
    public var body: [BodyMeasurement]
    public var workouts: [Workout]
    public var cycle: [CycleEntry]

    public init(days: [MergedDay] = [], meals: [Meal] = [], body: [BodyMeasurement] = [], workouts: [Workout] = [], cycle: [CycleEntry] = []) {
        self.days = days; self.meals = meals; self.body = body; self.workouts = workouts; self.cycle = cycle
    }
}

public enum TrendBuilder {
    /// One value per local day for `metric`. Days without data are omitted (not zero) except for
    /// cumulative activity metrics on days that have a metrics record.
    public static func dailyValues(_ metric: TrendMetric, inputs: TrendInputs, calendar: Calendar = .current) -> [LocalDate: Double] {
        var out: [LocalDate: Double] = [:]
        switch metric {
        case .weight, .bodyFatPct, .muscleMassKg:
            // Last measurement of each day.
            for m in inputs.body.sorted(by: { $0.measuredAt < $1.measuredAt }) {
                let v: Double? = metric == .weight ? m.weightKg : (metric == .bodyFatPct ? m.bodyFatPct : m.muscleMassKg)
                if let v { out[LocalDate(m.measuredAt, calendar: calendar)] = v }
            }
        case .kcalIn, .proteinG, .carbsG, .fatG, .fiberG:
            for meal in inputs.meals where !meal.deleted {
                let t = meal.totals
                let v: Double
                switch metric {
                case .kcalIn: v = t.kcal
                case .proteinG: v = t.proteinG
                case .carbsG: v = t.carbsG
                case .fatG: v = t.fatG
                default: v = t.fiberG
                }
                out[meal.date, default: 0] += v
            }
        case .sleepScore, .sleepMinutes, .hrvMs, .restingHr, .readinessScore, .activityScore, .steps, .activeKcal:
            let key: MetricKey
            switch metric {
            case .sleepScore: key = .sleepScore
            case .sleepMinutes: key = .sleepMinutes
            case .hrvMs: key = .hrvMs
            case .restingHr: key = .restingHr
            case .readinessScore: key = .readinessScore
            case .activityScore: key = .activityScore
            case .steps: key = .steps
            default: key = .activeKcal
            }
            for d in inputs.days { if let v = d.merged.value(for: key) { out[d.date] = v } }
        case .workoutMinutes:
            for w in inputs.workouts { out[LocalDate(w.start, calendar: calendar), default: 0] += w.durationMin }
        case .trainingLoad:
            let restingByDay = Dictionary(inputs.days.compactMap { d in d.merged.restingHr.map { (d.date, $0) } }, uniquingKeysWith: { a, _ in a })
            for w in inputs.workouts {
                let day = LocalDate(w.start, calendar: calendar)
                out[day, default: 0] += TrainingLoad.load(for: w, restingHr: restingByDay[day])
            }
        case .cycleDay:
            for c in inputs.cycle { if let d = c.cycleDay { out[c.date] = Double(d) } }
        }
        return out
    }

    public static func series(_ metric: TrendMetric, range: TrendRange, endingOn end: LocalDate, inputs: TrendInputs,
                              aggregation: TrendAggregation? = nil, calendar: Calendar = .current) -> TrendSeries {
        let start = end.adding(days: -(range.days - 1))
        let values = dailyValues(metric, inputs: inputs, calendar: calendar)
        var points = values.filter { $0.key >= start && $0.key <= end }.map { TrendPoint(date: $0.key, value: $0.value) }.sorted { $0.date < $1.date }
        if (aggregation ?? range.suggestedAggregation) == .week {
            points = weekly(points, cumulative: metric.isCumulative)
        }
        let s = Stats.summary(points)
        return TrendSeries(metric: metric, points: points, avg: s.avg, min: s.min, max: s.max, delta: s.delta)
    }

    /// Aggregates to ISO weeks (Monday start). Cumulative metrics use the mean *daily* value so weeks stay comparable to days.
    public static func weekly(_ points: [TrendPoint], cumulative: Bool) -> [TrendPoint] {
        let grouped = Dictionary(grouping: points) { $0.date.adding(days: -($0.date.isoWeekday - 1)) }
        return grouped.keys.sorted().map { week in
            let vals = grouped[week]!.map(\.value)
            return TrendPoint(date: week, value: vals.reduce(0, +) / Double(vals.count))
        }
    }
}
