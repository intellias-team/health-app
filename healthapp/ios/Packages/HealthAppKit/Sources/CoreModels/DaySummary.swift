import Foundation

/// Energy in vs out for one day. Resting, active, total expenditure and intake are kept separate on purpose
/// so the UI never collapses them into a single "calories remaining" number.
public struct EnergyBalance: Codable, Hashable, Sendable {
    public var restingKcal: Double
    public var activeKcal: Double
    public var intakeKcal: Double
    /// True if any logged food was a photo/voice estimate.
    public var intakeIsEstimate: Bool
    /// True when resting energy was estimated (e.g. Mifflin-St Jeor) because no source supplied it.
    public var restingIsEstimated: Bool

    public init(restingKcal: Double, activeKcal: Double, intakeKcal: Double, intakeIsEstimate: Bool = false, restingIsEstimated: Bool = false) {
        self.restingKcal = restingKcal; self.activeKcal = activeKcal; self.intakeKcal = intakeKcal
        self.intakeIsEstimate = intakeIsEstimate; self.restingIsEstimated = restingIsEstimated
    }

    public var totalExpenditureKcal: Double { restingKcal + activeKcal }
    /// Intake minus expenditure (negative when expenditure exceeds intake).
    public var balanceKcal: Double { intakeKcal - totalExpenditureKcal }
    /// Intake as a fraction of expenditure (0…∞).
    public var intakeRatio: Double { totalExpenditureKcal > 0 ? intakeKcal / totalExpenditureKcal : 0 }

    private enum CodingKeys: String, CodingKey { case restingKcal, activeKcal, intakeKcal, intakeIsEstimate, restingIsEstimated, totalExpenditureKcal, balanceKcal }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restingKcal = try c.decodeIfPresent(Double.self, forKey: .restingKcal) ?? 0
        activeKcal = try c.decodeIfPresent(Double.self, forKey: .activeKcal) ?? 0
        intakeKcal = try c.decodeIfPresent(Double.self, forKey: .intakeKcal) ?? 0
        intakeIsEstimate = try c.decodeIfPresent(Bool.self, forKey: .intakeIsEstimate) ?? false
        restingIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .restingIsEstimated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(restingKcal, forKey: .restingKcal)
        try c.encode(activeKcal, forKey: .activeKcal)
        try c.encode(intakeKcal, forKey: .intakeKcal)
        try c.encode(intakeIsEstimate, forKey: .intakeIsEstimate)
        try c.encode(restingIsEstimated, forKey: .restingIsEstimated)
        try c.encode(totalExpenditureKcal, forKey: .totalExpenditureKcal)
        try c.encode(balanceKcal, forKey: .balanceKcal)
    }
}

public enum InsightTone: String, Codable, Hashable, Sendable { case neutral, info, attention }

public struct Insight: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var message: String
    public var tone: InsightTone
    public init(id: String, kind: String, title: String, message: String, tone: InsightTone = .neutral) {
        self.id = id; self.kind = kind; self.title = title; self.message = message; self.tone = tone
    }
}

/// `GET /v1/day/{date}` — everything shown in Today and Calendar → Day detail.
public struct DaySummary: Codable, Hashable, Sendable {
    public var date: LocalDate
    public var meals: [Meal]
    public var totals: Nutrients
    public var workouts: [Workout]
    public var metrics: MetricValues
    public var body: [BodyMeasurement]
    public var note: Note?
    public var energyBalance: EnergyBalance?
    public var insights: [Insight]

    public init(date: LocalDate, meals: [Meal] = [], totals: Nutrients? = nil, workouts: [Workout] = [],
                metrics: MetricValues = MetricValues(), body: [BodyMeasurement] = [], note: Note? = nil,
                energyBalance: EnergyBalance? = nil, insights: [Insight] = []) {
        self.date = date; self.meals = meals
        self.totals = totals ?? meals.filter { !$0.deleted }.reduce(.zero) { $0 + $1.totals }
        self.workouts = workouts; self.metrics = metrics; self.body = body; self.note = note
        self.energyBalance = energyBalance; self.insights = insights
    }

    private enum CodingKeys: String, CodingKey { case date, meals, totals, workouts, metrics, body, note, energyBalance, insights }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(LocalDate.self, forKey: .date)
        meals = try c.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        totals = try c.decodeIfPresent(Nutrients.self, forKey: .totals) ?? meals.reduce(.zero) { $0 + $1.totals }
        workouts = try c.decodeIfPresent([Workout].self, forKey: .workouts) ?? []
        metrics = try c.decodeIfPresent(MetricValues.self, forKey: .metrics) ?? MetricValues()
        body = try c.decodeIfPresent([BodyMeasurement].self, forKey: .body) ?? []
        note = try c.decodeIfPresent(Note.self, forKey: .note)
        energyBalance = try c.decodeIfPresent(EnergyBalance.self, forKey: .energyBalance)
        insights = try c.decodeIfPresent([Insight].self, forKey: .insights) ?? []
    }

    public var activeMeals: [Meal] { meals.filter { !$0.deleted } }
    public var latestWeightKg: Double? { body.sorted { $0.measuredAt > $1.measuredAt }.first { $0.weightKg != nil }?.weightKg }
}
