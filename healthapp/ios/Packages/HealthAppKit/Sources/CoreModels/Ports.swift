import Foundation

// MARK: - Ports
//
// Service protocols ("ports") that feature UI and other modules depend on. Concrete adapters live in their
// own modules (HealthKitModule, OuraModule, AuthKit, NutritionKit, FoodRecognitionKit, SyncKit, MockData)
// and are wired together once, in the app's `AppEnvironment` composition root. Every integration can be
// swapped (live ↔ demo ↔ test double) without touching feature code.
//
// They live in CoreModels (Foundation only) so that every module, including Linux-testable ones, can see them
// without pulling in Apple frameworks.

public struct AuthSession: Codable, Hashable, Sendable {
    /// Cognito `sub` — the only user identifier the backend trusts.
    public var userId: String
    public var email: String?
    public var expiresAt: Date
    public init(userId: String, email: String? = nil, expiresAt: Date) { self.userId = userId; self.email = email; self.expiresAt = expiresAt }
}

/// Cognito Hosted UI + Sign in with Apple.
public protocol AuthService: Sendable {
    func currentSession() async -> AuthSession?
    /// Presents the Hosted UI (identity_provider=SignInWithApple) and stores tokens in the Keychain.
    func signIn() async throws -> AuthSession
    /// A valid access token, refreshing if it expires within the refresh window. Throws if signed out.
    func accessToken() async throws -> String
    func signOut() async
}

/// Apple Health (or any equivalent on-device health store).
public protocol HealthDataSource: Sendable {
    var isAvailable: Bool { get }
    func requestAuthorization(read: Set<HealthMetricType>, write: Set<HealthMetricType>) async throws
    func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [DailyMetrics]
    func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout]
    func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement]
    func save(bodyMeasurement: BodyMeasurement) async throws
    /// Writes dietary energy/macros/fiber/sugar/sodium for a meal.
    func save(meal: Meal) async throws
    func save(waterMl: Double, at date: Date) async throws
    /// Registers observer queries + background delivery; `onUpdate` fires when new samples arrive.
    func startBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) async
}

public struct OuraSyncResult: Codable, Hashable, Sendable {
    public var daysUpserted: Int
    public var workoutsUpserted: Int
    public init(daysUpserted: Int, workoutsUpserted: Int) { self.daysUpserted = daysUpserted; self.workoutsUpserted = workoutsUpserted }
}

/// Oura is integrated server-side (OAuth tokens never touch the device); the app only starts the OAuth
/// flow and triggers syncs.
public protocol OuraService: Sendable {
    func connect() async throws
    func disconnect() async throws
    func sync(from: LocalDate?, to: LocalDate?) async throws -> OuraSyncResult
}

/// A smart body scale integration (via HealthKit or direct BLE).
public protocol BodyScaleProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func measurements(since: Date) async throws -> [BodyMeasurement]
}

/// Nutrition database (USDA FDC / Open Food Facts / custom foods via the backend).
public protocol NutritionDatabase: Sendable {
    func search(query: String, limit: Int) async throws -> [FoodSummary]
    func food(_ ref: FoodRef) async throws -> FoodDetail
    /// nil when the barcode is unknown (404).
    func barcode(_ gtin: String) async throws -> FoodDetail?
    func saveCustomFood(_ food: CustomFood) async throws -> CustomFood
}

/// AI meal recognition — photo and voice.
public protocol MealRecognitionService: Sendable {
    /// `jpegData` must already be downscaled with metadata stripped.
    func analyzePhoto(jpegData: Data, mealId: String, scaleReadings: [ScaleReadingInput], hint: String?,
                      category: MealCategory?) async throws -> (analysis: MealAnalysis, photoKey: String?)
    func parseVoice(transcript: String, category: MealCategory?) async throws -> [AnalyzedItem]
}

public protocol CoachService: Sendable {
    func ask(_ message: String, conversationId: String) async throws -> CoachReply
}

public protocol SyncService: Sendable {
    func pendingChangeCount() async -> Int
    /// Push the outbox then pull remote changes.
    func syncNow() async throws -> SyncReport
}

public struct AccountSnapshot: Codable, Hashable, Sendable {
    public var profile: Profile
    public var goals: Goals
    public var connections: [Connection]
    public init(profile: Profile, goals: Goals, connections: [Connection]) { self.profile = profile; self.goals = goals; self.connections = connections }
}

/// Read/write facade over user data used by every feature screen.
/// Live: backend + SwiftData cache + outbox. Demo: in-memory generated data.
public protocol HealthRepository: Sendable {
    func daySummary(for date: LocalDate) async throws -> DaySummary
    func meals(from: LocalDate, to: LocalDate) async throws -> [Meal]
    func saveMeal(_ meal: Meal) async throws -> Meal
    func deleteMeal(_ meal: Meal) async throws
    func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [MergedDay]
    func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement]
    func addBodyMeasurement(_ measurement: BodyMeasurement) async throws
    func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout]
    func saveNote(_ note: Note) async throws
    func trend(_ metric: TrendMetric, range: TrendRange) async throws -> TrendSeries
    func compare(x: TrendMetric, y: TrendMetric, range: TrendRange, lagDays: Int) async throws -> CompareResult
    func recipes() async throws -> [Recipe]
    func saveRecipe(_ recipe: Recipe) async throws -> Recipe
    func customFoods() async throws -> [CustomFood]
    func account() async throws -> AccountSnapshot
    func updateProfile(_ profile: Profile) async throws -> Profile
    func updateGoals(_ goals: Goals) async throws -> Goals
    func updateConnection(provider: String, enabledMetrics: [String], status: ConnectionStatus) async throws -> Connection
    func saveCycleEntry(_ entry: CycleEntry) async throws
    func exportData() async throws -> URL
    func deleteAccount() async throws
}
