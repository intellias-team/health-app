import Foundation
import CoreModels
import AnalyticsKit

/// In-memory `HealthRepository` backed by `DemoDataProvider`. All writes work (and persist for the session).
public actor DemoRepository: HealthRepository {
    private var data: DemoDataset
    private var settings: DataSourceSettings
    private let calendar: Calendar

    public init(dataset: DemoDataset? = nil, settings: DataSourceSettings = DataSourceSettings(), calendar: Calendar = .current) {
        self.data = dataset ?? DemoDataProvider.generate(calendar: calendar)
        self.settings = settings
        self.calendar = calendar
    }

    public func updateSettings(_ s: DataSourceSettings) { settings = s }

    // MARK: Helpers

    private func merged(from: LocalDate, to: LocalDate) -> [MergedDay] {
        MetricMerger.merge(days: data.dailyMetrics.filter { $0.date >= from && $0.date <= to }, settings: settings)
    }

    private func liveMeals(from: LocalDate, to: LocalDate) -> [Meal] {
        data.meals.filter { !$0.deleted && $0.date >= from && $0.date <= to }.sorted { $0.loggedAt < $1.loggedAt }
    }

    private func inputs(from: LocalDate, to: LocalDate) -> TrendInputs {
        TrendInputs(days: merged(from: from, to: to), meals: liveMeals(from: from, to: to),
                    body: data.body.filter { LocalDate($0.measuredAt, calendar: calendar) >= from && LocalDate($0.measuredAt, calendar: calendar) <= to },
                    workouts: data.workouts.filter { LocalDate($0.start, calendar: calendar) >= from && LocalDate($0.start, calendar: calendar) <= to },
                    cycle: data.profile.cycleTrackingEnabled ? data.cycle.filter { $0.date >= from && $0.date <= to } : [])
    }

    /// Snapshot for services (coach) that compute over the demo data.
    public func dataset() -> DemoDataset { data }

    // MARK: HealthRepository

    public func daySummary(for date: LocalDate) async throws -> DaySummary {
        let meals = liveMeals(from: date, to: date)
        let metrics = merged(from: date, to: date).first?.merged ?? MetricValues()
        let workouts = data.workouts.filter { LocalDate($0.start, calendar: calendar) == date }.sorted { $0.start < $1.start }
        let body = data.body.filter { LocalDate($0.measuredAt, calendar: calendar) == date }
        let note = data.notes.first { $0.date == date }
        let balance = EnergyBalanceCalculator.balance(metrics: metrics, meals: meals)
        let isToday = date == LocalDate.today(calendar: calendar)
        let progress = isToday ? min(1, max(0, (EnergyBalanceCalculator.dayFraction(at: Date(), calendar: calendar) * 24 - 6) / 16)) : 1
        let loads = TrainingLoad.dailyLoads(workouts, restingHr: metrics.restingHr, calendar: calendar)
        var insights: [Insight] = []
        if let fueling = FuelingInsightEngine.evaluate(balance: balance, trainingLoad: loads[date] ?? 0, readiness: metrics.readinessScore,
                                                       dayProgress: progress, mealsLogged: meals.count) {
            insights.append(fueling.asInsight)
        }
        return DaySummary(date: date, meals: meals, workouts: workouts, metrics: metrics, body: body, note: note,
                          energyBalance: balance, insights: insights)
    }

    public func meals(from: LocalDate, to: LocalDate) async throws -> [Meal] { liveMeals(from: from, to: to) }

    public func saveMeal(_ meal: Meal) async throws -> Meal {
        var m = meal
        m.updatedAt = Date()
        m.recomputeTotals()
        if let idx = data.meals.firstIndex(where: { $0.id == m.id }) {
            m.version = data.meals[idx].version + 1
            data.meals[idx] = m
        } else {
            m.version = 1
            data.meals.append(m)
        }
        return m
    }

    public func deleteMeal(_ meal: Meal) async throws {
        data.meals.removeAll { $0.id == meal.id }
    }

    public func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [MergedDay] { merged(from: from, to: to) }

    public func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement] {
        data.body.filter { let d = LocalDate($0.measuredAt, calendar: calendar); return d >= from && d <= to }.sorted { $0.measuredAt < $1.measuredAt }
    }

    public func addBodyMeasurement(_ measurement: BodyMeasurement) async throws { data.body.append(measurement) }

    public func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout] {
        data.workouts.filter { let d = LocalDate($0.start, calendar: calendar); return d >= from && d <= to }.sorted { $0.start < $1.start }
    }

    public func saveNote(_ note: Note) async throws {
        data.notes.removeAll { $0.date == note.date }
        if !note.text.isEmpty || !note.tags.isEmpty { data.notes.append(note) }
    }

    public func trend(_ metric: TrendMetric, range: TrendRange) async throws -> TrendSeries {
        let end = LocalDate.today(calendar: calendar)
        return TrendBuilder.series(metric, range: range, endingOn: end, inputs: inputs(from: end.adding(days: -range.days), to: end), calendar: calendar)
    }

    public func compare(x: TrendMetric, y: TrendMetric, range: TrendRange, lagDays: Int) async throws -> CompareResult {
        let end = LocalDate.today(calendar: calendar)
        let inp = inputs(from: end.adding(days: -range.days - 1), to: end)
        let xs = TrendBuilder.series(x, range: range, endingOn: end, inputs: inp, aggregation: .day, calendar: calendar).points
        let ys = TrendBuilder.series(y, range: range, endingOn: end, inputs: inp, aggregation: .day, calendar: calendar).points
        return CorrelationAnalyzer.compare(xMetric: x, yMetric: y, x: xs, y: ys, lagDays: lagDays)
    }

    public func recipes() async throws -> [Recipe] { data.recipes }

    public func saveRecipe(_ recipe: Recipe) async throws -> Recipe {
        data.recipes.removeAll { $0.id == recipe.id }
        data.recipes.append(recipe)
        return recipe
    }

    public func customFoods() async throws -> [CustomFood] { data.customFoods }

    public func addCustomFood(_ food: CustomFood) {
        data.customFoods.removeAll { $0.id == food.id }
        data.customFoods.append(food)
    }

    public func account() async throws -> AccountSnapshot { AccountSnapshot(profile: data.profile, goals: data.goals, connections: data.connections) }

    public func updateProfile(_ profile: Profile) async throws -> Profile { data.profile = profile; return profile }

    public func updateGoals(_ goals: Goals) async throws -> Goals { data.goals = goals; return goals }

    public func updateConnection(provider: String, enabledMetrics: [String], status: ConnectionStatus) async throws -> Connection {
        let c = Connection(provider: provider, status: status, enabledMetrics: enabledMetrics, lastSyncAt: Date())
        data.connections.removeAll { $0.provider == provider }
        data.connections.append(c)
        return c
    }

    public func saveCycleEntry(_ entry: CycleEntry) async throws {
        data.cycle.removeAll { $0.date == entry.date }
        data.cycle.append(entry)
    }

    public func exportData() async throws -> URL {
        struct Export: Encodable { var profile: Profile; var goals: Goals; var meals: [Meal]; var body: [BodyMeasurement]; var workouts: [Workout]; var notes: [Note] }
        let export = Export(profile: data.profile, goals: data.goals, meals: data.meals, body: data.body, workouts: data.workouts, notes: data.notes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("healthapp-export-\(LocalDate.today().iso).json")
        try JSONCoding.makeEncoder(pretty: true).encode(export).write(to: url)
        return url
    }

    public func deleteAccount() async throws {
        data = DemoDataset(profile: Profile(), goals: .default, connections: [], dailyMetrics: [], meals: [], workouts: [], body: [], notes: [], cycle: [], recipes: [], customFoods: [])
    }
}
