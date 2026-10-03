#if canImport(SwiftData)
import Foundation
import CoreModels
import Networking
import AnalyticsKit

/// Live `HealthRepository`: backend first, SwiftData cache as offline fallback, user-owned writes go
/// through the local store + outbox (offline-first) and are pushed by the `SyncEngine`.
public actor LiveHealthRepository: HealthRepository {
    private let api: APIClient
    private let store: LocalStore
    private let sync: SyncEngine
    private var customFoodCache: [CustomFood] = []

    public init(api: APIClient, store: LocalStore, sync: SyncEngine) {
        self.api = api; self.store = store; self.sync = sync
    }

    private func syncSoon() {
        let sync = self.sync
        Task.detached(priority: .utility) { _ = try? await sync.syncNow() }
    }

    // MARK: Day

    public func daySummary(for date: LocalDate) async throws -> DaySummary {
        let localMeals = (try? await store.meals(from: date, to: date)) ?? []
        do {
            var summary = try await api.send(API.day(date))
            // Overlay meals that exist only locally (not yet pushed) and local edits pending upload.
            let pending = Set(try await store.pendingEntries(limit: 1000).map(\.change.id))
            var byID = Dictionary(summary.meals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for m in localMeals where pending.contains(m.id) || byID[m.id] == nil { byID[m.id] = m }
            summary.meals = byID.values.filter { !$0.deleted }.sorted { $0.loggedAt < $1.loggedAt }
            summary.totals = summary.meals.reduce(.zero) { $0 + $1.totals }
            if let note = try? await store.note(for: date), pending.contains(date.iso) { summary.note = note }
            return summary
        } catch {
            return try await offlineSummary(for: date, meals: localMeals)
        }
    }

    private func offlineSummary(for date: LocalDate, meals: [Meal]) async throws -> DaySummary {
        let metrics = MetricMerger.merge(days: (try? await store.cachedMetrics(from: date, to: date)) ?? []).first?.merged ?? MetricValues()
        let workouts = (try? await store.cachedWorkouts(from: date.startDate(), to: date.endDate())) ?? []
        let body = (try? await store.cachedBody(from: date.startDate(), to: date.endDate())) ?? []
        let note = try? await store.note(for: date)
        let balance = EnergyBalanceCalculator.balance(metrics: metrics, meals: meals)
        return DaySummary(date: date, meals: meals, workouts: workouts, metrics: metrics, body: body, note: note, energyBalance: balance)
    }

    // MARK: Meals

    public func meals(from: LocalDate, to: LocalDate) async throws -> [Meal] {
        if let remote = try? await api.send(API.meals(from: from, to: to)) {
            try? await store.cacheServerMeals(remote.meals)
        }
        return try await store.meals(from: from, to: to)
    }

    public func saveMeal(_ meal: Meal) async throws -> Meal {
        var m = meal
        m.updatedAt = Date()
        m.recomputeTotals()
        try await store.saveMeal(m)
        syncSoon()
        return m
    }

    public func deleteMeal(_ meal: Meal) async throws {
        try await store.deleteMeal(meal)
        syncSoon()
    }

    // MARK: Health data

    public func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [MergedDay] {
        do {
            let days = try await api.send(API.dailyMetrics(from: from, to: to)).days
            let flattened = days.flatMap { day in
                day.bySource.compactMap { key, values in MetricSource(rawValue: key).map { DailyMetrics(date: day.date, source: $0, metrics: values) } }
            }
            try? await store.cache(metrics: flattened)
            return days
        } catch {
            return MetricMerger.merge(days: try await store.cachedMetrics(from: from, to: to))
        }
    }

    public func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement] {
        do {
            let m = try await api.send(API.body(from: from, to: to)).measurements
            try? await store.cache(body: m)
            return m
        } catch {
            return try await store.cachedBody(from: from.startDate(), to: to.endDate())
        }
    }

    public func addBodyMeasurement(_ measurement: BodyMeasurement) async throws {
        try await store.cache(body: [measurement])
        _ = try await api.send(try API.postBody([measurement]))
    }

    public func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout] {
        do {
            let w = try await api.send(API.workouts(from: from, to: to)).workouts
            try? await store.cache(workouts: w)
            return w
        } catch {
            return try await store.cachedWorkouts(from: from.startDate(), to: to.endDate())
        }
    }

    public func saveNote(_ note: Note) async throws {
        try await store.saveNote(note)
        syncSoon()
    }

    // MARK: Trends

    public func trend(_ metric: TrendMetric, range: TrendRange) async throws -> TrendSeries {
        do {
            return try await api.send(API.trend(metric, range: range))
        } catch {
            let end = LocalDate.today()
            let inputs = try await offlineInputs(from: end.adding(days: -range.days), to: end)
            return TrendBuilder.series(metric, range: range, endingOn: end, inputs: inputs)
        }
    }

    public func compare(x: TrendMetric, y: TrendMetric, range: TrendRange, lagDays: Int) async throws -> CompareResult {
        do {
            return try await api.send(API.compare(x: x, y: y, range: range, lagDays: lagDays))
        } catch {
            let end = LocalDate.today()
            let inputs = try await offlineInputs(from: end.adding(days: -range.days - 1), to: end)
            let xs = TrendBuilder.series(x, range: range, endingOn: end, inputs: inputs, aggregation: .day).points
            let ys = TrendBuilder.series(y, range: range, endingOn: end, inputs: inputs, aggregation: .day).points
            return CorrelationAnalyzer.compare(xMetric: x, yMetric: y, x: xs, y: ys, lagDays: lagDays)
        }
    }

    private func offlineInputs(from: LocalDate, to: LocalDate) async throws -> TrendInputs {
        TrendInputs(days: MetricMerger.merge(days: try await store.cachedMetrics(from: from, to: to)),
                    meals: try await store.meals(from: from, to: to),
                    body: try await store.cachedBody(from: from.startDate(), to: to.endDate()),
                    workouts: try await store.cachedWorkouts(from: from.startDate(), to: to.endDate()))
    }

    // MARK: Recipes & custom foods

    public func recipes() async throws -> [Recipe] { try await api.send(API.recipes()).recipes }

    public func saveRecipe(_ recipe: Recipe) async throws -> Recipe { try await api.send(try API.putRecipe(recipe)).recipe }

    /// The API has no list route for custom foods (they're returned by `/v1/foods/search`), so this returns
    /// the ones created on this device in this session.
    public func customFoods() async throws -> [CustomFood] { customFoodCache }

    public func rememberCustomFood(_ food: CustomFood) {
        customFoodCache.removeAll { $0.id == food.id }
        customFoodCache.insert(food, at: 0)
    }

    // MARK: Account

    public func account() async throws -> AccountSnapshot { try await api.send(API.me()) }
    public func updateProfile(_ profile: Profile) async throws -> Profile { try await api.send(try API.updateProfile(profile)).profile }
    public func updateGoals(_ goals: Goals) async throws -> Goals { try await api.send(try API.updateGoals(goals)).goals }
    public func updateConnection(provider: String, enabledMetrics: [String], status: ConnectionStatus) async throws -> Connection {
        try await api.send(try API.updateConnection(provider: provider, enabledMetrics: enabledMetrics, status: status)).connection
    }
    public func saveCycleEntry(_ entry: CycleEntry) async throws { _ = try await api.send(try API.putCycle(entry)) }
    public func exportData() async throws -> URL { try await api.send(API.exportData()).downloadUrl }

    public func deleteAccount() async throws {
        _ = try await api.send(API.deleteAccount())
        try await store.eraseAll()
    }
}
#endif
