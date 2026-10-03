import Foundation

/// Where a metric came from (docs/02 §2.2 "Daily metrics" `source`).
public enum MetricSource: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case healthkit, oura, manual, bodyscale, foodscale
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .healthkit: return "Apple Health"
        case .oura: return "Oura Ring"
        case .manual: return "Manual entry"
        case .bodyscale: return "Smart body scale"
        case .foodscale: return "Food scale"
        }
    }
}

/// Keys of the normalised daily metrics map (docs/02 §2.2.3).
public enum MetricKey: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case steps, activeKcal, restingKcal, restingHr, hrvMs, sleepMinutes, sleepStages, sleepScore
    case readinessScore, activityScore, tempDeviationC, respiratoryRate, spo2Pct, waterMl, vo2max

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .steps: return "Steps"
        case .activeKcal: return "Active energy"
        case .restingKcal: return "Resting energy"
        case .restingHr: return "Resting heart rate"
        case .hrvMs: return "Heart rate variability"
        case .sleepMinutes: return "Sleep duration"
        case .sleepStages: return "Sleep stages"
        case .sleepScore: return "Sleep score"
        case .readinessScore: return "Readiness"
        case .activityScore: return "Activity score"
        case .tempDeviationC: return "Temperature deviation"
        case .respiratoryRate: return "Respiratory rate"
        case .spo2Pct: return "Blood oxygen"
        case .waterMl: return "Water"
        case .vo2max: return "VO₂ max"
        }
    }

    /// Default source precedence (docs/02 §2.2.3 "Source precedence"): Oura for sleep/readiness/HRV/temperature,
    /// HealthKit for steps/energy/workouts/body.
    public var defaultPrecedence: [MetricSource] {
        switch self {
        case .sleepMinutes, .sleepStages, .sleepScore, .readinessScore, .hrvMs, .tempDeviationC, .respiratoryRate, .restingHr, .spo2Pct:
            return [.manual, .oura, .healthkit]
        case .activityScore:
            return [.manual, .oura, .healthkit]
        default:
            return [.manual, .healthkit, .oura]
        }
    }
}

/// Sleep stage minutes (docs/02 §2.2.3 `sleepStages`): HealthKit asleepCore/Deep/REM/Unspecified, awake, inBed;
/// Oura light→coreMin, deep, rem, awake_time.
public struct SleepStages: Codable, Hashable, Sendable {
    public var coreMin: Double
    public var deepMin: Double
    public var remMin: Double
    public var awakeMin: Double
    public var unspecifiedMin: Double
    public var inBedMin: Double
    public var napMin: Double

    public init(coreMin: Double = 0, deepMin: Double = 0, remMin: Double = 0, awakeMin: Double = 0,
                unspecifiedMin: Double = 0, inBedMin: Double = 0, napMin: Double = 0) {
        self.coreMin = coreMin; self.deepMin = deepMin; self.remMin = remMin; self.awakeMin = awakeMin
        self.unspecifiedMin = unspecifiedMin; self.inBedMin = inBedMin; self.napMin = napMin
    }

    private enum CodingKeys: String, CodingKey { case coreMin, deepMin, remMin, awakeMin, unspecifiedMin, inBedMin, napMin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? 0 }
        coreMin = try v(.coreMin); deepMin = try v(.deepMin); remMin = try v(.remMin); awakeMin = try v(.awakeMin)
        unspecifiedMin = try v(.unspecifiedMin); inBedMin = try v(.inBedMin); napMin = try v(.napMin)
    }

    /// Main-sleep minutes asleep (naps excluded).
    public var asleepMin: Double { coreMin + deepMin + remMin + unspecifiedMin }
}

/// Normalised per-day metrics. Every field optional because each source supplies a subset.
public struct MetricValues: Codable, Hashable, Sendable {
    public var steps: Double?
    public var activeKcal: Double?
    public var restingKcal: Double?
    public var restingHr: Double?
    public var hrvMs: Double?
    /// "sleepLowest" for Oura's lowest sleeping HR; nil for Apple's resting HR. Trends never mix methods.
    public var restingHrMethod: String?
    /// "sdnn" (HealthKit) or "rmssd" (Oura) — the two are not directly comparable.
    public var hrvMethod: String?
    public var sleepMinutes: Double?
    /// Start of the main sleep period (ISO timestamp), used for sleep-consistency insights.
    public var bedtimeStart: Date?
    public var sleepStages: SleepStages?
    public var sleepScore: Double?
    public var readinessScore: Double?
    public var activityScore: Double?
    public var tempDeviationC: Double?
    public var respiratoryRate: Double?
    public var spo2Pct: Double?
    public var waterMl: Double?
    public var vo2max: Double?

    public init(steps: Double? = nil, activeKcal: Double? = nil, restingKcal: Double? = nil, restingHr: Double? = nil, restingHrMethod: String? = nil,
                hrvMs: Double? = nil, hrvMethod: String? = nil, sleepMinutes: Double? = nil, sleepStages: SleepStages? = nil,
                sleepScore: Double? = nil, readinessScore: Double? = nil, activityScore: Double? = nil,
                tempDeviationC: Double? = nil, respiratoryRate: Double? = nil, spo2Pct: Double? = nil,
                waterMl: Double? = nil, vo2max: Double? = nil) {
        self.steps = steps; self.activeKcal = activeKcal; self.restingKcal = restingKcal; self.restingHr = restingHr; self.restingHrMethod = restingHrMethod
        self.hrvMs = hrvMs; self.hrvMethod = hrvMethod; self.sleepMinutes = sleepMinutes; self.sleepStages = sleepStages
        self.sleepScore = sleepScore; self.readinessScore = readinessScore; self.activityScore = activityScore
        self.tempDeviationC = tempDeviationC; self.respiratoryRate = respiratoryRate; self.spo2Pct = spo2Pct
        self.waterMl = waterMl; self.vo2max = vo2max
    }

    /// Scalar accessor by key (sleepStages returns asleep minutes).
    public func value(for key: MetricKey) -> Double? {
        switch key {
        case .steps: return steps
        case .activeKcal: return activeKcal
        case .restingKcal: return restingKcal
        case .restingHr: return restingHr
        case .hrvMs: return hrvMs
        case .sleepMinutes: return sleepMinutes
        case .sleepStages: return sleepStages?.asleepMin
        case .sleepScore: return sleepScore
        case .readinessScore: return readinessScore
        case .activityScore: return activityScore
        case .tempDeviationC: return tempDeviationC
        case .respiratoryRate: return respiratoryRate
        case .spo2Pct: return spo2Pct
        case .waterMl: return waterMl
        case .vo2max: return vo2max
        }
    }

    /// Copies one key from another value set (used by the source-precedence merger).
    public mutating func take(_ key: MetricKey, from other: MetricValues) {
        switch key {
        case .steps: steps = other.steps
        case .activeKcal: activeKcal = other.activeKcal
        case .restingKcal: restingKcal = other.restingKcal
        case .restingHr: restingHr = other.restingHr; restingHrMethod = other.restingHrMethod
        case .hrvMs: hrvMs = other.hrvMs; hrvMethod = other.hrvMethod
        case .sleepMinutes: sleepMinutes = other.sleepMinutes
        case .sleepStages: sleepStages = other.sleepStages
        case .sleepScore: sleepScore = other.sleepScore
        case .readinessScore: readinessScore = other.readinessScore
        case .activityScore: activityScore = other.activityScore
        case .tempDeviationC: tempDeviationC = other.tempDeviationC
        case .respiratoryRate: respiratoryRate = other.respiratoryRate
        case .spo2Pct: spo2Pct = other.spo2Pct
        case .waterMl: waterMl = other.waterMl
        case .vo2max: vo2max = other.vo2max
        }
    }

    public func has(_ key: MetricKey) -> Bool {
        key == .sleepStages ? sleepStages != nil : value(for: key) != nil
    }
}

/// One source's metrics for one day (`DAY#<date>#<source>`), as POSTed to `/v1/metrics/daily`.
public struct DailyMetrics: Codable, Hashable, Sendable {
    public var date: LocalDate
    public var source: MetricSource
    public var metrics: MetricValues
    public init(date: LocalDate, source: MetricSource, metrics: MetricValues) {
        self.date = date; self.source = source; self.metrics = metrics
    }
}

/// `GET /v1/metrics/daily` day entry.
public struct MergedDay: Codable, Hashable, Sendable {
    public var date: LocalDate
    public var merged: MetricValues
    public var bySource: [String: MetricValues]
    public init(date: LocalDate, merged: MetricValues, bySource: [String: MetricValues] = [:]) {
        self.date = date; self.merged = merged; self.bySource = bySource
    }
}

/// Body measurement (`BODY#<ts>#<id>`).
public struct BodyMeasurement: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var measuredAt: Date
    public var source: String
    public var weightKg: Double?
    public var bodyFatPct: Double?
    public var muscleMassKg: Double?
    public var leanMassKg: Double?
    public var bmi: Double?
    public var visceralFat: Double?
    public var waterPct: Double?
    public var boneMassKg: Double?
    public var bmrKcal: Double?

    public init(id: String = UUID().uuidString.lowercased(), measuredAt: Date, source: String, weightKg: Double? = nil,
                bodyFatPct: Double? = nil, muscleMassKg: Double? = nil, leanMassKg: Double? = nil, bmi: Double? = nil,
                visceralFat: Double? = nil, waterPct: Double? = nil, boneMassKg: Double? = nil, bmrKcal: Double? = nil) {
        self.id = id; self.measuredAt = measuredAt; self.source = source; self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct; self.muscleMassKg = muscleMassKg; self.leanMassKg = leanMassKg; self.bmi = bmi
        self.visceralFat = visceralFat; self.waterPct = waterPct; self.boneMassKg = boneMassKg; self.bmrKcal = bmrKcal
    }
}

/// Workout (`WORKOUT#<start>#<id>`).
public struct Workout: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var start: Date
    public var end: Date
    public var type: String
    public var source: MetricSource
    public var durationMin: Double
    public var activeKcal: Double?
    public var avgHr: Double?
    public var maxHr: Double?
    public var distanceM: Double?
    /// Training load (TRIMP).
    public var load: Double?
    public var externalId: String?

    public init(id: String = UUID().uuidString.lowercased(), start: Date, end: Date, type: String, source: MetricSource,
                durationMin: Double? = nil, activeKcal: Double? = nil, avgHr: Double? = nil, maxHr: Double? = nil,
                distanceM: Double? = nil, load: Double? = nil, externalId: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.type = type; self.source = source
        self.durationMin = durationMin ?? end.timeIntervalSince(start) / 60
        self.activeKcal = activeKcal; self.avgHr = avgHr; self.maxHr = maxHr; self.distanceM = distanceM
        self.load = load; self.externalId = externalId
    }

    public var displayType: String {
        type.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

public struct Note: Codable, Hashable, Sendable {
    public var date: LocalDate
    public var text: String
    public var tags: [String]
    public init(date: LocalDate, text: String, tags: [String] = []) { self.date = date; self.text = text; self.tags = tags }
}

public struct CycleEntry: Codable, Hashable, Sendable {
    public var date: LocalDate
    public var flow: String?
    public var phase: String?
    public var symptoms: [String]
    /// Day of cycle (1 = first day of period), derived client-side for the Compare view.
    public var cycleDay: Int?
    public init(date: LocalDate, flow: String? = nil, phase: String? = nil, symptoms: [String] = [], cycleDay: Int? = nil) {
        self.date = date; self.flow = flow; self.phase = phase; self.symptoms = symptoms; self.cycleDay = cycleDay
    }
}
