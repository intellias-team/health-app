import Foundation
import Observation
import CoreModels
import AnalyticsKit
import FoodScaleKit
import NotificationsKit
import MockData
// Concrete adapters — only the composition root imports these.
import Networking
import AuthKit
import HealthKitModule
import OuraModule
import BodyScaleKit
import NutritionKit
import FoodRecognitionKit
import SyncKit
import SwiftData

/// Composition root + app-wide observable state.
///
/// Chooses **Live** (backend + HealthKit + Oura + SwiftData/outbox) or **Demo** (90 days of generated data,
/// no network) and exposes every integration through its protocol so feature screens never depend on a
/// concrete adapter.
@MainActor
@Observable
final class AppEnvironment {
    enum Mode: String { case demo, live }

    let mode: Mode
    let config: AppConfig

    // Ports
    let repository: any HealthRepository
    let auth: any AuthService
    let health: any HealthDataSource
    let oura: any OuraService
    let nutrition: any NutritionDatabase
    let recognition: any MealRecognitionService
    let coach: any CoachService
    let sync: any SyncService
    let bodyScales: [any BodyScaleProvider]
    let foodScale: FoodScaleManager
    @ObservationIgnored let notifications = NotificationScheduler()
    @ObservationIgnored private let api: APIClient?
    @ObservationIgnored private let connectivity = ConnectivityMonitor()

    // State
    var session: AuthSession?
    var profile = Profile()
    var goals = Goals.default
    var connections: [Connection] = []
    var dataSourceSettings: DataSourceSettings { didSet { persist(dataSourceSettings, key: Keys.dataSources) } }
    var notificationPrefs: NotificationPreferences { didSet { persist(notificationPrefs, key: Keys.notifications) } }
    var writeMealsToHealth: Bool { didSet { UserDefaults.standard.set(writeMealsToHealth, forKey: Keys.writeMeals) } }
    var hasOnboarded: Bool { didSet { UserDefaults.standard.set(hasOnboarded, forKey: Keys.onboarded) } }
    /// Bumped after any write so screens reload.
    var dataVersion = 0
    var lastSync: SyncReport?
    var lastError: String?
    var isSyncing = false
    /// Navigation shared across tabs (e.g. Today → "Log food" opens the Food tab's add sheet).
    var selectedTab: AppTab = .today
    var pendingAddFood: AddFoodRoute?

    @ObservationIgnored private var lastHealthUpload: Date = .distantPast
    @ObservationIgnored private var liveServicesStarted = false

    private enum Keys {
        static let dataSources = "settings.dataSources"
        static let notifications = "settings.notifications"
        static let writeMeals = "settings.writeMealsToHealth"
        static let onboarded = "app.onboarded"
        static let liveOverride = "HealthAppLiveMode" // launch argument: -HealthAppLiveMode YES
    }

    // MARK: Bootstrap

    static func bootstrap() -> AppEnvironment {
        let config = AppConfig.fromBundle()
        #if targetEnvironment(simulator)
        let simulatorDemo = !UserDefaults.standard.bool(forKey: Keys.liveOverride)
        #else
        let simulatorDemo = false
        #endif
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if config.isComplete && !simulatorDemo && !isTesting {
            return AppEnvironment(live: config)
        }
        return AppEnvironment(demo: config)
    }

    /// Demo mode: every screen works offline with generated data.
    init(demo config: AppConfig) {
        let repo = DemoRepository()
        mode = .demo
        self.config = config
        repository = repo
        auth = DemoAuthService(signedIn: true)
        health = DemoHealthDataSource(repository: repo)
        oura = DemoOuraService()
        nutrition = DemoNutritionDatabase(repository: repo)
        recognition = DemoMealRecognitionService()
        coach = DemoCoachService(repository: repo)
        sync = DemoSyncService()
        bodyScales = [DemoBodyScaleProvider(repository: repo)]
        foodScale = FoodScaleManager(registry: .standard) // simulated in the Simulator, real BLE on device
        api = nil
        dataSourceSettings = Self.load(DataSourceSettings.self, key: Keys.dataSources) ?? DataSourceSettings()
        notificationPrefs = Self.load(NotificationPreferences.self, key: Keys.notifications) ?? NotificationPreferences()
        writeMealsToHealth = UserDefaults.standard.object(forKey: Keys.writeMeals) as? Bool ?? true
        hasOnboarded = UserDefaults.standard.bool(forKey: Keys.onboarded)
        session = AuthSession(userId: "demo-user", email: "demo@healthapp.example", expiresAt: .distantFuture)
    }

    /// Live mode: Cognito + API Gateway/Lambda + HealthKit + Oura (server-side) + SwiftData outbox.
    init(live config: AppConfig) {
        let cognito = CognitoAuthService(config: CognitoConfig(domain: config.cognitoDomain, clientId: config.cognitoClientId,
                                                               region: config.cognitoRegion))
        let api = APIClient(baseURL: config.apiBaseURL!) { force in try await cognito.accessToken(forceRefresh: force) }
        let container: ModelContainer
        do { container = try LocalStore.makeContainer() }
        catch { container = try! LocalStore.makeContainer(inMemory: true) } // last resort: keep the app usable
        let store = LocalStore(modelContainer: container)
        let engine = SyncEngine(api: api, store: store)
        let healthKit = HealthKitService()

        mode = .live
        self.config = config
        self.api = api
        repository = LiveHealthRepository(api: api, store: store, sync: engine)
        auth = cognito
        health = healthKit
        oura = OuraConnectionService(api: api)
        nutrition = RemoteNutritionDatabase(api: api)
        recognition = MealPhotoPipeline(api: api)
        coach = RemoteCoachService(api: api)
        sync = engine
        bodyScales = [HealthKitBodyScaleProvider(health: healthKit)]
        foodScale = FoodScaleManager(registry: .standard)
        dataSourceSettings = Self.load(DataSourceSettings.self, key: Keys.dataSources) ?? DataSourceSettings()
        notificationPrefs = Self.load(NotificationPreferences.self, key: Keys.notifications) ?? NotificationPreferences()
        writeMealsToHealth = UserDefaults.standard.object(forKey: Keys.writeMeals) as? Bool ?? true
        hasOnboarded = UserDefaults.standard.bool(forKey: Keys.onboarded)
    }

    // MARK: Lifecycle

    func start() async {
        session = await auth.currentSession()
        notifications.registerCategories()
        guard session != nil else { return }
        await loadAccount()
        if mode == .live && !liveServicesStarted {
            liveServicesStarted = true
            connectivity.start { [weak self] in
                Task { @MainActor in await self?.syncNow() }
            }
            await health.startBackgroundDelivery { [weak self] in
                await self?.uploadHealthData(days: 2)
            }
            await syncNow()
            await uploadHealthData(days: 7)
        }
    }

    func loadAccount() async {
        do {
            let account = try await repository.account()
            profile = account.profile
            goals = account.goals
            connections = account.connections
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signIn() async throws {
        session = try await auth.signIn()
        await start()
    }

    func signOut() async {
        await auth.signOut()
        session = nil
    }

    /// Foreground / BGAppRefreshTask entry point.
    func performBackgroundRefresh() async {
        await syncNow()
        await uploadHealthData(days: 2)
    }

    func syncNow() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            lastSync = try await sync.syncNow()
            if (lastSync?.pulled ?? 0) > 0 { dataVersion += 1 }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Writes used by many screens

    @discardableResult
    func saveMeal(_ meal: Meal) async throws -> Meal {
        let saved = try await repository.saveMeal(meal)
        if writeMealsToHealth && dataSourceSettings.isEnabled(provider: "healthkit", metric: HealthMetricType.dietaryEnergy.rawValue) {
            try? await health.save(meal: saved)
        }
        dataVersion += 1
        await updateProteinNudge()
        return saved
    }

    func deleteMeal(_ meal: Meal) async throws {
        try await repository.deleteMeal(meal)
        dataVersion += 1
    }

    func addBodyMeasurement(_ m: BodyMeasurement, writeToHealth: Bool) async throws {
        try await repository.addBodyMeasurement(m)
        if writeToHealth { try? await health.save(bodyMeasurement: m) }
        dataVersion += 1
    }

    func saveNote(_ note: Note) async throws {
        try await repository.saveNote(note)
        dataVersion += 1
    }

    func updateGoals(_ g: Goals) async {
        do { goals = try await repository.updateGoals(g) } catch { lastError = error.localizedDescription }
        dataVersion += 1
    }

    func updateProfile(_ p: Profile) async {
        do { profile = try await repository.updateProfile(p) } catch { lastError = error.localizedDescription }
        dataVersion += 1
    }

    /// Persists a per-source permission change locally and mirrors it to `PUT /v1/connections/{provider}`.
    func setMetric(_ metric: String, enabled: Bool, for source: DataSourceDescriptor) {
        dataSourceSettings.setEnabled(enabled, provider: source.id, metric: metric, allMetrics: source.metrics)
        let enabledList = source.metrics.filter { dataSourceSettings.isEnabled(provider: source.id, metric: $0) }
        let status = connections.first { $0.provider == source.id }?.status ?? .connected
        Task {
            _ = try? await repository.updateConnection(provider: source.id, enabledMetrics: enabledList, status: status)
            if let demo = repository as? DemoRepository { await demo.updateSettings(dataSourceSettings) }
            dataVersion += 1
        }
    }

    func setPrecedence(_ order: [MetricSource], for key: MetricKey) {
        dataSourceSettings.precedence[key] = order
        if let demo = repository as? DemoRepository {
            let s = dataSourceSettings
            Task { await demo.updateSettings(s); dataVersion += 1 }
        }
    }

    /// Registers (or refreshes) this device for APNs pushes and server-side notification preferences.
    func registerDevice(apnsToken: String? = nil) async {
        if let apnsToken { UserDefaults.standard.set(apnsToken, forKey: "device.apnsToken") }
        guard let api, let token = apnsToken ?? UserDefaults.standard.string(forKey: "device.apnsToken") else { return }
        let idKey = "device.id"
        let id = UserDefaults.standard.string(forKey: idKey) ?? {
            let new = UUID().uuidString.lowercased()
            UserDefaults.standard.set(new, forKey: idKey)
            return new
        }()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let registration = DeviceRegistration(id: id, apnsToken: token, appVersion: version, notificationPrefs: notificationPrefs)
        _ = try? await api.send(try API.registerDevice(registration))
    }

    func applyNotificationPrefs() async {
        await registerDevice()
        await notifications.apply(notificationPrefs, bedtimeMinutes: Int(goals.sleepHours > 0 ? (24 - goals.sleepHours + 6.5) * 60 : 22.5 * 60) % (24 * 60))
    }

    private func updateProteinNudge() async {
        guard let today = try? await repository.daySummary(for: .today()) else { return }
        await notifications.scheduleProteinProgress(consumed: today.totals.proteinG, goal: goals.proteinG,
                                                    enabled: notificationPrefs.proteinGoalProgress)
    }

    /// Posts a local low-recovery alert once per day when readiness is low (opt-in).
    func checkLowRecovery(_ summary: DaySummary) async {
        guard notificationPrefs.lowRecoveryAlerts, summary.date == .today(), let r = summary.metrics.readinessScore, r < 60 else { return }
        let key = "alert.lowRecovery.\(summary.date.iso)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let copy = NotificationCopy.lowRecovery(readiness: Int(r))
        await notifications.notifyNow(.lowRecovery, title: copy.title, body: copy.body)
    }

    // MARK: HealthKit → backend (docs/03 §3.4 step 5: idempotent batches, not the outbox)

    func uploadHealthData(days: Int) async {
        guard mode == .live, let api, health.isAvailable, Date().timeIntervalSince(lastHealthUpload) > 120 else { return }
        lastHealthUpload = Date()
        let to = LocalDate.today(), from = to.adding(days: -(days - 1))
        do {
            let raw = try await health.dailyMetrics(from: from, to: to)
            let filtered = raw.map { Self.filter($0, settings: dataSourceSettings) }
            for start in stride(from: 0, to: filtered.count, by: 31) {
                _ = try await api.send(try API.postDailyMetrics(Array(filtered[start..<min(start + 31, filtered.count)])))
            }
            if dataSourceSettings.isEnabled(provider: "healthkit", metric: HealthMetricType.bodyMass.rawValue) {
                let body = try await health.bodyMeasurements(from: from, to: to)
                if !body.isEmpty { _ = try await api.send(try API.postBody(body)) }
            }
            if dataSourceSettings.isEnabled(provider: "healthkit", metric: HealthMetricType.workouts.rawValue) {
                let workouts = try await health.workouts(from: from, to: to)
                if !workouts.isEmpty { _ = try await api.send(try API.postWorkouts(workouts)) }
            }
            dataVersion += 1
        } catch {
            lastError = error.localizedDescription
            if notificationPrefs.deviceSyncFailures {
                let copy = NotificationCopy.syncFailure(source: "Apple Health")
                await notifications.notifyNow(.syncFailure, title: copy.title, body: copy.body)
            }
        }
    }

    /// Drops HealthKit metrics the user switched off in Settings → Data Sources.
    static func filter(_ day: DailyMetrics, settings: DataSourceSettings) -> DailyMetrics {
        var d = day
        func on(_ t: HealthMetricType) -> Bool { settings.isEnabled(provider: "healthkit", metric: t.rawValue) }
        if !on(.steps) { d.metrics.steps = nil }
        if !on(.activeEnergy) { d.metrics.activeKcal = nil }
        if !on(.restingEnergy) { d.metrics.restingKcal = nil }
        if !on(.restingHeartRate) { d.metrics.restingHr = nil }
        if !on(.hrv) { d.metrics.hrvMs = nil; d.metrics.hrvMethod = nil }
        if !on(.sleep) { d.metrics.sleepMinutes = nil; d.metrics.sleepStages = nil; d.metrics.bedtimeStart = nil }
        if !on(.water) { d.metrics.waterMl = nil }
        if !on(.vo2max) { d.metrics.vo2max = nil }
        if !on(.respiratoryRate) { d.metrics.respiratoryRate = nil }
        if !on(.wristTemperature) { d.metrics.tempDeviationC = nil }
        return d
    }

    // MARK: Deep links

    /// `healthapp://oura/connected`, `healthapp://oura/error?reason=…` (the ASWebAuthenticationSession normally
    /// captures these; this handles the case where Safari opened the app instead).
    func handle(url: URL) {
        guard url.scheme == "healthapp" else { return }
        if url.host == "oura" {
            switch OuraConnectionService.parseCallback(url) {
            case .success: Task { await loadAccount(); dataVersion += 1 }
            case .failure(let e): lastError = e.localizedDescription
            }
        }
    }

    // MARK: Persistence helpers

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

