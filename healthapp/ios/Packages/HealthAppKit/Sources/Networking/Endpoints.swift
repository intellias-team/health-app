import Foundation
import CoreModels

// MARK: - Response envelopes (docs/03 §3.3)

public struct ProfileEnvelope: Codable, Sendable { public var profile: Profile }
public struct GoalsEnvelope: Codable, Sendable { public var goals: Goals }
public struct ExportResponse: Codable, Sendable { public var downloadUrl: URL }
public struct ConnectionsEnvelope: Codable, Sendable { public var connections: [Connection] }
public struct ConnectionEnvelope: Codable, Sendable { public var connection: Connection }
public struct DeviceEnvelope: Codable, Sendable { public var device: DeviceRegistration }
public struct MealsEnvelope: Codable, Sendable { public var meals: [Meal] }
public struct MealEnvelope: Codable, Sendable { public var meal: Meal }
public struct FoodsEnvelope: Codable, Sendable { public var foods: [FoodSummary] }
public struct FoodEnvelope: Codable, Sendable { public var food: FoodDetail }
public struct CustomFoodEnvelope: Codable, Sendable { public var food: CustomFood }
public struct RecipesEnvelope: Codable, Sendable { public var recipes: [Recipe] }
public struct RecipeEnvelope: Codable, Sendable { public var recipe: Recipe }
public struct UpsertedResponse: Codable, Sendable { public var upserted: Int }
public struct DailyMetricsEnvelope: Codable, Sendable { public var days: [MergedDay] }
public struct BodyEnvelope: Codable, Sendable { public var measurements: [BodyMeasurement] }
public struct WorkoutsEnvelope: Codable, Sendable { public var workouts: [Workout] }
public struct NoteEnvelope: Codable, Sendable { public var note: Note }
public struct CycleEnvelope: Codable, Sendable { public var entry: CycleEntry }
public struct UploadURLResponse: Codable, Sendable {
    public var uploadUrl: URL
    public var photoKey: String
    public var expiresIn: Int
    /// Every header here (content-type, S3 retention tag…) MUST be sent on the PUT or the signature fails.
    public var requiredHeaders: [String: String]?
    public var maxBytes: Int?
}
public struct VoiceParseResponse: Codable, Sendable { public var items: [AnalyzedItem] }
public struct OuraAuthorizeResponse: Codable, Sendable { public var authorizeUrl: URL }

// MARK: - Request bodies

public struct ConnectionUpdateBody: Codable, Sendable { public var enabledMetrics: [String]; public var status: ConnectionStatus }
public struct DailyMetricsBody: Codable, Sendable { public var days: [DailyMetrics] }
public struct BodyBody: Codable, Sendable { public var measurements: [BodyMeasurement] }
public struct WorkoutsBody: Codable, Sendable { public var workouts: [Workout] }
public struct NoteBody: Codable, Sendable { public var text: String; public var tags: [String] }
public struct UploadURLBody: Codable, Sendable { public var mealId: String; public var contentType: String; public var contentLength: Int? }
public struct MealAnalysisBody: Codable, Sendable {
    public var photoKey: String
    public var scaleReadings: [ScaleReadingInput]?
    public var hint: String?
    public var mealCategory: MealCategory?
    public init(photoKey: String, scaleReadings: [ScaleReadingInput]? = nil, hint: String? = nil, mealCategory: MealCategory? = nil) {
        self.photoKey = photoKey; self.scaleReadings = scaleReadings; self.hint = hint; self.mealCategory = mealCategory
    }
}
public struct VoiceParseBody: Codable, Sendable {
    public var transcript: String
    public var mealCategory: MealCategory?
    public init(transcript: String, mealCategory: MealCategory? = nil) { self.transcript = transcript; self.mealCategory = mealCategory }
}
public struct CoachBody: Codable, Sendable {
    public var conversationId: String
    public var message: String
    public init(conversationId: String, message: String) { self.conversationId = conversationId; self.message = message }
}
public struct OuraSyncBody: Codable, Sendable { public var from: LocalDate?; public var to: LocalDate? }

// MARK: - Routes

/// Every route of the HealthApp API (docs/03 §3.3), as typed `Endpoint`s.
public enum API {
    /// Percent-encodes one dynamic path segment.
    public static func segment(_ s: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func range(_ from: LocalDate, _ to: LocalDate) -> [QueryItem] { [QueryItem("from", from.iso), QueryItem("to", to.iso)] }

    // Profile, goals, permissions
    public static func me() -> Endpoint<AccountSnapshot> { Endpoint(.get, "/v1/me") }
    public static func updateProfile(_ p: Profile) throws -> Endpoint<ProfileEnvelope> { try Endpoint(.put, "/v1/me", json: p) }
    public static func updateGoals(_ g: Goals) throws -> Endpoint<GoalsEnvelope> { try Endpoint(.put, "/v1/me/goals", json: g) }
    public static func deleteAccount() -> Endpoint<EmptyResponse> { Endpoint(.delete, "/v1/me") }
    public static func exportData() -> Endpoint<ExportResponse> { Endpoint(.post, "/v1/me/export") }
    public static func connections() -> Endpoint<ConnectionsEnvelope> { Endpoint(.get, "/v1/connections") }
    public static func updateConnection(provider: String, enabledMetrics: [String], status: ConnectionStatus) throws -> Endpoint<ConnectionEnvelope> {
        try Endpoint(.put, "/v1/connections/\(segment(provider))", json: ConnectionUpdateBody(enabledMetrics: enabledMetrics, status: status))
    }
    public static func registerDevice(_ d: DeviceRegistration) throws -> Endpoint<DeviceEnvelope> {
        try Endpoint(.post, "/v1/devices", json: d, idempotencyKey: d.id)
    }

    // Nutrition
    public static func meals(from: LocalDate, to: LocalDate) -> Endpoint<MealsEnvelope> { Endpoint(.get, "/v1/meals", query: range(from, to)) }
    public static func putMeal(_ meal: Meal) throws -> Endpoint<MealEnvelope> {
        try Endpoint(.put, "/v1/meals/\(segment(meal.id))", json: meal, idempotencyKey: meal.id)
    }
    /// `date` is optional and only speeds up the server-side lookup.
    public static func deleteMeal(id: String, date: LocalDate? = nil) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/v1/meals/\(segment(id))", query: date.map { [QueryItem("date", $0.iso)] } ?? [], idempotencyKey: id)
    }
    public static func searchFoods(_ q: String, limit: Int = 25) -> Endpoint<FoodsEnvelope> {
        Endpoint(.get, "/v1/foods/search", query: [QueryItem("q", q), QueryItem("limit", String(min(25, max(1, limit))))])
    }
    public static func barcode(_ gtin: String) -> Endpoint<FoodEnvelope> { Endpoint(.get, "/v1/foods/barcode/\(segment(gtin))") }
    public static func food(_ ref: FoodRef) -> Endpoint<FoodEnvelope> { Endpoint(.get, "/v1/foods/\(ref.db.rawValue)/\(segment(ref.id))") }
    public static func putCustomFood(_ f: CustomFood) throws -> Endpoint<CustomFoodEnvelope> {
        try Endpoint(.put, "/v1/foods/custom/\(segment(f.id))", json: f, idempotencyKey: f.id)
    }
    public static func recipes() -> Endpoint<RecipesEnvelope> { Endpoint(.get, "/v1/recipes") }
    public static func putRecipe(_ r: Recipe) throws -> Endpoint<RecipeEnvelope> {
        try Endpoint(.put, "/v1/recipes/\(segment(r.id))", json: r, idempotencyKey: r.id)
    }
    public static func deleteRecipe(id: String) -> Endpoint<EmptyResponse> { Endpoint(.delete, "/v1/recipes/\(segment(id))", idempotencyKey: id) }

    // Health data
    public static func postDailyMetrics(_ days: [DailyMetrics]) throws -> Endpoint<UpsertedResponse> {
        precondition(days.count <= 31, "batch ≤ 31 days")
        return try Endpoint(.post, "/v1/metrics/daily", json: DailyMetricsBody(days: days), idempotencyKey: UUID().uuidString)
    }
    public static func dailyMetrics(from: LocalDate, to: LocalDate) -> Endpoint<DailyMetricsEnvelope> { Endpoint(.get, "/v1/metrics/daily", query: range(from, to)) }
    public static func postBody(_ m: [BodyMeasurement]) throws -> Endpoint<UpsertedResponse> {
        try Endpoint(.post, "/v1/body", json: BodyBody(measurements: m), idempotencyKey: UUID().uuidString)
    }
    public static func body(from: LocalDate, to: LocalDate) -> Endpoint<BodyEnvelope> { Endpoint(.get, "/v1/body", query: range(from, to)) }
    public static func postWorkouts(_ w: [Workout]) throws -> Endpoint<UpsertedResponse> {
        try Endpoint(.post, "/v1/workouts", json: WorkoutsBody(workouts: w), idempotencyKey: UUID().uuidString)
    }
    public static func workouts(from: LocalDate, to: LocalDate) -> Endpoint<WorkoutsEnvelope> { Endpoint(.get, "/v1/workouts", query: range(from, to)) }
    public static func putNote(_ note: Note) throws -> Endpoint<NoteEnvelope> {
        try Endpoint(.put, "/v1/notes/\(note.date.iso)", json: NoteBody(text: note.text, tags: note.tags), idempotencyKey: "note-\(note.date.iso)")
    }
    public static func putCycle(_ e: CycleEntry) throws -> Endpoint<CycleEnvelope> {
        try Endpoint(.put, "/v1/cycle/\(e.date.iso)", json: e, idempotencyKey: "cycle-\(e.date.iso)")
    }
    public static func day(_ date: LocalDate) -> Endpoint<DaySummary> { Endpoint(.get, "/v1/day/\(date.iso)") }
    public static func trend(_ metric: TrendMetric, range: TrendRange, agg: TrendAggregation? = nil) -> Endpoint<TrendSeries> {
        Endpoint(.get, "/v1/trends/\(metric.rawValue)", query: [QueryItem("range", range.rawValue), QueryItem("agg", (agg ?? range.suggestedAggregation).rawValue)])
    }
    public static func compare(x: TrendMetric, y: TrendMetric, range: TrendRange, lagDays: Int) -> Endpoint<CompareResult> {
        Endpoint(.get, "/v1/trends/compare", query: [QueryItem("x", x.rawValue), QueryItem("y", y.rawValue),
                                                     QueryItem("range", range.rawValue), QueryItem("lagDays", String(lagDays == 1 ? 1 : 0))])
    }

    // AI
    public static func photoUploadURL(mealId: String, contentLength: Int? = nil) throws -> Endpoint<UploadURLResponse> {
        try Endpoint(.post, "/v1/photos/upload-url", json: UploadURLBody(mealId: mealId, contentType: "image/jpeg", contentLength: contentLength),
                     idempotencyKey: "upload-\(mealId)")
    }
    public static func mealAnalysis(_ body: MealAnalysisBody) throws -> Endpoint<MealAnalysis> {
        try Endpoint(.post, "/v1/ai/meal-analysis", json: body)
    }
    public static func voiceParse(_ body: VoiceParseBody) throws -> Endpoint<VoiceParseResponse> { try Endpoint(.post, "/v1/ai/voice-parse", json: body) }
    public static func coach(_ body: CoachBody) throws -> Endpoint<CoachReply> { try Endpoint(.post, "/v1/ai/coach", json: body) }

    // Oura
    public static func ouraAuthorize() -> Endpoint<OuraAuthorizeResponse> { Endpoint(.post, "/v1/integrations/oura/authorize") }
    public static func ouraSync(from: LocalDate?, to: LocalDate?) throws -> Endpoint<OuraSyncResult> {
        try Endpoint(.post, "/v1/integrations/oura/sync", json: OuraSyncBody(from: from, to: to))
    }
    public static func ouraDisconnect() -> Endpoint<EmptyResponse> { Endpoint(.delete, "/v1/integrations/oura") }

    // Sync
    public static func syncPush(_ changes: [SyncChange]) throws -> Endpoint<SyncPushResponse> {
        precondition(changes.count <= 100, "≤ 100 changes per push")
        return try Endpoint(.post, "/v1/sync/push", json: SyncPushRequest(changes: changes), idempotencyKey: UUID().uuidString)
    }
    public static func syncPull(since cursor: String?, limit: Int = 200) -> Endpoint<SyncPullResponse> {
        var q = [QueryItem("limit", String(min(200, limit)))]
        if let cursor { q.insert(QueryItem("since", cursor), at: 0) }
        return Endpoint(.get, "/v1/sync/pull", query: q)
    }
}
