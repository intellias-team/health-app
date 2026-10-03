import Foundation
import CoreModels

/// Training load using Banister's TRIMP with sensible fallbacks when heart-rate data is missing.
public enum TrainingLoad {
    /// Banister TRIMP = duration(min) × ΔHR ratio × 0.64·e^(1.92·ΔHR) (male) or 0.86·e^(1.67·ΔHR) (female).
    public static func trimp(durationMin: Double, avgHr: Double, restingHr: Double, maxHr: Double, sex: BiologicalSex? = nil) -> Double {
        guard durationMin > 0, maxHr > restingHr else { return 0 }
        let ratio = Swift.min(1, Swift.max(0, (avgHr - restingHr) / (maxHr - restingHr)))
        let weighting: Double
        switch sex {
        case .female: weighting = 0.86 * exp(1.67 * ratio)
        case .male: weighting = 0.64 * exp(1.92 * ratio)
        default: weighting = 0.75 * exp(1.795 * ratio) // average of both
        }
        return durationMin * ratio * weighting
    }

    /// Typical relative intensity by workout type when no heart-rate data exists (rough HR-reserve ratio).
    static func fallbackIntensity(for type: String) -> Double {
        let t = type.lowercased()
        if t.contains("hiit") || t.contains("interval") || t.contains("crossfit") { return 0.75 }
        if t.contains("run") || t.contains("cycl") || t.contains("row") || t.contains("swim") { return 0.65 }
        if t.contains("strength") || t.contains("weight") || t.contains("functional") { return 0.55 }
        if t.contains("yoga") || t.contains("walk") || t.contains("pilates") || t.contains("stretch") { return 0.35 }
        return 0.5
    }

    /// Load for one workout: explicit `load` → HR TRIMP → type-based fallback.
    public static func load(for workout: Workout, restingHr: Double? = nil, maxHr: Double? = nil, sex: BiologicalSex? = nil) -> Double {
        if let load = workout.load { return load }
        let rest = restingHr ?? 60
        let mx = maxHr ?? 190
        if let avg = workout.avgHr {
            return trimp(durationMin: workout.durationMin, avgHr: avg, restingHr: rest, maxHr: mx, sex: sex)
        }
        let ratio = fallbackIntensity(for: workout.type)
        return trimp(durationMin: workout.durationMin, avgHr: rest + ratio * (mx - rest), restingHr: rest, maxHr: mx, sex: sex)
    }

    /// Sum of load per local day of workout start.
    public static func dailyLoads(_ workouts: [Workout], restingHr: Double? = nil, maxHr: Double? = nil, calendar: Calendar = .current) -> [LocalDate: Double] {
        var result: [LocalDate: Double] = [:]
        for w in workouts {
            result[LocalDate(w.start, calendar: calendar), default: 0] += load(for: w, restingHr: restingHr, maxHr: maxHr)
        }
        return result
    }

    public struct AcuteChronic: Hashable, Sendable {
        /// Mean daily load over the last 7 days.
        public var acute: Double
        /// Mean daily load over the last 28 days.
        public var chronic: Double
        /// acute / chronic (nil when chronic is ~0).
        public var ratio: Double?

        public enum Status: String, Sendable { case building = "Building", steady = "Steady", elevated = "Elevated", lighter = "Lighter than usual" }
        public var status: Status {
            guard let ratio else { return .building }
            switch ratio {
            case ..<0.8: return .lighter
            case 0.8...1.3: return .steady
            default: return .elevated
            }
        }
    }

    public static func acuteChronic(dailyLoads: [LocalDate: Double], on date: LocalDate) -> AcuteChronic {
        func avg(days: Int) -> Double {
            var sum = 0.0
            for i in 0..<days { sum += dailyLoads[date.adding(days: -i)] ?? 0 }
            return sum / Double(days)
        }
        let acute = avg(days: 7), chronic = avg(days: 28)
        return AcuteChronic(acute: acute, chronic: chronic, ratio: chronic > 1 ? acute / chronic : nil)
    }
}
