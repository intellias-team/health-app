import Foundation
import CoreModels
import NutritionKit
import AnalyticsKit

/// Simulated latency so loading states are visible in demo mode.
func demoDelay(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

public actor DemoAuthService: AuthService {
    private var session: AuthSession?
    public init(signedIn: Bool = true) {
        session = signedIn ? AuthSession(userId: "demo-user", email: "demo@healthapp.example", expiresAt: .distantFuture) : nil
    }
    public func currentSession() async -> AuthSession? { session }
    public func signIn() async throws -> AuthSession {
        await demoDelay(0.6)
        let s = AuthSession(userId: "demo-user", email: "demo@healthapp.example", expiresAt: .distantFuture)
        session = s
        return s
    }
    public func accessToken() async throws -> String { "demo-token" }
    public func signOut() async { session = nil }
}

/// Health store stand-in: reads come from the demo dataset, writes are accepted and dropped.
public struct DemoHealthDataSource: HealthDataSource {
    private let repository: DemoRepository
    public init(repository: DemoRepository) { self.repository = repository }
    public var isAvailable: Bool { true }
    public func requestAuthorization(read: Set<HealthMetricType>, write: Set<HealthMetricType>) async throws { await demoDelay(0.3) }
    public func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [DailyMetrics] {
        await repository.dataset().dailyMetrics.filter { $0.source == .healthkit && $0.date >= from && $0.date <= to }
    }
    public func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout] { try await repository.workouts(from: from, to: to) }
    public func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement] { try await repository.bodyMeasurements(from: from, to: to) }
    public func save(bodyMeasurement: BodyMeasurement) async throws {}
    public func save(meal: Meal) async throws {}
    public func save(waterMl: Double, at date: Date) async throws {}
    public func startBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) async {}
}

public struct DemoOuraService: OuraService {
    public init() {}
    public func connect() async throws { await demoDelay(1.0) }
    public func disconnect() async throws { await demoDelay(0.4) }
    public func sync(from: LocalDate?, to: LocalDate?) async throws -> OuraSyncResult {
        await demoDelay(0.8)
        return OuraSyncResult(daysUpserted: 2, workoutsUpserted: 1)
    }
}

public struct DemoNutritionDatabase: NutritionDatabase {
    private let repository: DemoRepository?
    public init(repository: DemoRepository? = nil) { self.repository = repository }

    public func search(query: String, limit: Int) async throws -> [FoodSummary] {
        await demoDelay(0.25)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var foods = DemoFoodCatalog.foods
        if let repository { foods += await repository.dataset().customFoods.map(\.asDetail) }
        let hits = q.isEmpty ? foods : foods.filter { $0.name.lowercased().contains(q) || ($0.brand?.lowercased().contains(q) ?? false) }
        return hits.prefix(limit).map {
            FoodSummary(foodRef: $0.foodRef, name: $0.name, brand: $0.brand, nutrientsPer100g: $0.nutrientsPer100g,
                        servingG: $0.portions.first?.grams, servingLabel: $0.portions.first?.label, isRestaurant: $0.brand == "Restaurant")
        }
    }

    public func food(_ ref: FoodRef) async throws -> FoodDetail {
        if let f = DemoFoodCatalog.food(ref) { return f }
        if ref.db == .custom, let repository, let c = await repository.dataset().customFoods.first(where: { $0.id == ref.id }) { return c.asDetail }
        throw DemoError.notFound
    }

    public func barcode(_ gtin: String) async throws -> FoodDetail? {
        await demoDelay(0.3)
        if let id = DemoFoodCatalog.barcodes[gtin] { return DemoFoodCatalog.foods.first { $0.foodRef.id == id } }
        // Any other barcode resolves to the protein bar so the flow can be tried with real packaging.
        return DemoFoodCatalog.foods.first { $0.foodRef.id == "p-bar" }
    }

    public func saveCustomFood(_ food: CustomFood) async throws -> CustomFood {
        await repository?.addCustomFood(food)
        return food
    }
}

public enum DemoError: Error, LocalizedError {
    case notFound
    public var errorDescription: String? { "Not found in the demo catalog." }
}

/// Returns a plausible analysis for any photo. Items matched to food-scale readings come back as "scale".
public struct DemoMealRecognitionService: MealRecognitionService {
    public init() {}

    static func analyzed(_ name: String, grams: Double, low: Double, high: Double, confidence: Double, weighed: Bool, id: String) -> AnalyzedItem? {
        guard let food = DemoFoodCatalog.food(named: name) else { return nil }
        let n = NutritionCalculator.nutrients(per100g: food.nutrientsPer100g, grams: grams).rounded
        let range = weighed ? NutrientRange.exact(n.kcal)
            : NutritionCalculator.kcalRange(per100g: food.nutrientsPer100g, gramsLow: low, gramsHigh: high)
        return AnalyzedItem(id: id, name: food.name, confidence: confidence, foodRef: food.foodRef, grams: grams,
                            gramsLow: weighed ? grams : low, gramsHigh: weighed ? grams : high,
                            weightSource: weighed ? .scale : .estimated, nutrients: n,
                            range: NutrientRange(kcalLow: range.kcalLow.rounded(), kcalHigh: range.kcalHigh.rounded()),
                            alternatives: [FoodAlternative(name: food.name.replacingOccurrences(of: "grilled", with: "roasted"))])
    }

    public func analyzePhoto(jpegData: Data, mealId: String, scaleReadings: [ScaleReadingInput], hint: String?,
                             category: MealCategory?) async throws -> (analysis: MealAnalysis, photoKey: String?) {
        await demoDelay(1.6)
        let weighed = scaleReadings.first?.grams
        let items = [
            Self.analyzed("Salmon", grams: weighed ?? 150, low: 110, high: 200, confidence: 0.88, weighed: weighed != nil, id: "i1"),
            Self.analyzed("Quinoa", grams: 170, low: 120, high: 230, confidence: 0.74, weighed: false, id: "i2"),
            Self.analyzed("Broccoli", grams: 90, low: 60, high: 130, confidence: 0.91, weighed: false, id: "i3"),
            Self.analyzed("Olive oil", grams: 8, low: 3, high: 15, confidence: 0.42, weighed: false, id: "i4"),
        ].compactMap { $0 }
        let analysis = MealAnalysis(analysisId: UUID().uuidString, items: items, isEstimate: true,
                                    questions: ["Was the salmon cooked with oil or butter?"], model: "demo")
        return (analysis, "demo/\(mealId).jpg")
    }

    /// Very small parser: "200 g chicken and a cup of rice" → items.
    public func parseVoice(transcript: String, category: MealCategory?) async throws -> [AnalyzedItem] {
        await demoDelay(0.8)
        let lower = transcript.lowercased()
        var items: [AnalyzedItem] = []
        let words = lower.replacingOccurrences(of: ",", with: " ").split(separator: " ").map(String.init)
        for (i, food) in DemoFoodCatalog.foods.enumerated() {
            let key = food.name.lowercased().split(separator: ",").first.map(String.init) ?? food.name.lowercased()
            let firstWord = key.split(separator: " ").first.map(String.init) ?? key
            guard firstWord.count > 3, lower.contains(firstWord) else { continue }
            var grams = food.portions.first?.grams ?? 100
            if let idx = words.firstIndex(where: { $0.hasPrefix(firstWord) }) {
                for j in stride(from: idx - 1, through: max(0, idx - 4), by: -1) {
                    if let v = Double(words[j].replacingOccurrences(of: "g", with: "")) { grams = v; break }
                }
            }
            if let a = Self.analyzed(food.name, grams: grams, low: grams * 0.75, high: grams * 1.3, confidence: 0.7, weighed: false, id: "v\(i)") {
                items.append(a)
            }
            if items.count >= 5 { break }
        }
        return items
    }
}

/// Data-grounded canned coach for demo mode. Answers cite the metrics they used.
public struct DemoCoachService: CoachService {
    private let repository: DemoRepository
    public init(repository: DemoRepository) { self.repository = repository }

    public func ask(_ message: String, conversationId: String) async throws -> CoachReply {
        await demoDelay(1.0)
        let today = LocalDate.today()
        let weekAgo = today.adding(days: -6)
        let q = message.lowercased()
        let days = try await repository.dailyMetrics(from: today.adding(days: -60), to: today)
        let meals = try await repository.meals(from: today.adding(days: -60), to: today)

        func avg(_ key: MetricKey, _ from: LocalDate, _ to: LocalDate) -> Double? {
            Stats.mean(days.filter { $0.date >= from && $0.date <= to }.compactMap { $0.merged.value(for: key) })
        }

        if q.contains("protein") {
            let byDay = Dictionary(grouping: meals.filter { $0.date >= weekAgo }, by: \.date).mapValues { $0.reduce(0) { $0 + $1.totals.proteinG } }
            let a = Stats.mean(Array(byDay.values)) ?? 0
            return CoachReply(reply: "Over the last 7 days you averaged about \(Int(a)) g of protein per day across \(byDay.count) logged days. Days with a lunch photo estimate carry some uncertainty, so the true figure could be a little higher or lower.",
                              citations: [CoachCitation(metric: "proteinG", from: weekAgo, to: today)], disclaimer: CoachCopy.disclaimer)
        }
        if q.contains("tired") {
            let sleepNow = avg(.sleepMinutes, weekAgo, today) ?? 0
            let sleepPrev = avg(.sleepMinutes, today.adding(days: -13), today.adding(days: -7)) ?? 0
            let hrvNow = avg(.hrvMs, weekAgo, today) ?? 0
            let hrvPrev = avg(.hrvMs, today.adding(days: -13), today.adding(days: -7)) ?? 0
            return CoachReply(reply: "A few things in your data may be related: average sleep this week is \(Units.formatDuration(minutes: sleepNow)) vs \(Units.formatDuration(minutes: sleepPrev)) the week before, and average HRV is \(Int(hrvNow)) ms vs \(Int(hrvPrev)) ms. Training load and how much you've eaten on training days can also play a part. Tiredness has many causes, so if it persists it's worth checking in with a professional.",
                              citations: [CoachCitation(metric: "sleepMinutes", from: today.adding(days: -13), to: today), CoachCitation(metric: "hrvMs", from: today.adding(days: -13), to: today)],
                              disclaimer: CoachCopy.disclaimer)
        }
        if q.contains("sleep") {
            let now = avg(.sleepScore, today.adding(days: -29), today) ?? 0
            let prev = avg(.sleepScore, today.adding(days: -59), today.adding(days: -30)) ?? 0
            let dir = now > prev + 1 ? "higher" : (now < prev - 1 ? "lower" : "about the same")
            return CoachReply(reply: "Your average sleep score over the last 30 days is \(Int(now)), \(dir) than the previous 30 days (\(Int(prev))).",
                              citations: [CoachCitation(metric: "sleepScore", from: today.adding(days: -59), to: today)], disclaimer: CoachCopy.disclaimer)
        }
        if q.contains("sodium") {
            let items = meals.filter { $0.date == today }.flatMap(\.items).sorted { $0.nutrients.sodiumMg > $1.nutrients.sodiumMg }.prefix(3)
            let list = items.map { "\($0.name) (\(Int($0.nutrients.sodiumMg)) mg)" }.joined(separator: ", ")
            return CoachReply(reply: items.isEmpty ? "You haven't logged any food today yet." : "Today's biggest sodium contributors so far: \(list).",
                              citations: [CoachCitation(metric: "sodiumMg", from: today, to: today)], disclaimer: CoachCopy.disclaimer)
        }
        if q.contains("training") || q.contains("volume") || q.contains("workout") {
            let w = try await repository.workouts(from: today.adding(days: -13), to: today)
            let this = w.filter { LocalDate($0.start) >= weekAgo }
            let last = w.filter { LocalDate($0.start) < weekAgo }
            let mThis = this.reduce(0) { $0 + $1.durationMin }, mLast = last.reduce(0) { $0 + $1.durationMin }
            let lThis = this.reduce(0) { $0 + TrainingLoad.load(for: $1) }, lLast = last.reduce(0) { $0 + TrainingLoad.load(for: $1) }
            return CoachReply(reply: "This week: \(this.count) workouts, \(Int(mThis)) minutes, training load \(Int(lThis)). Last week: \(last.count) workouts, \(Int(mLast)) minutes, load \(Int(lLast)).",
                              citations: [CoachCitation(metric: "trainingLoad", from: today.adding(days: -13), to: today)], disclaimer: CoachCopy.disclaimer)
        }
        return CoachReply(reply: "I can look at your logged food, activity, sleep, recovery and body data. Try asking about protein, sleep, training volume or how you've been feeling this week.",
                          disclaimer: CoachCopy.disclaimer)
    }
}

public actor DemoSyncService: SyncService {
    public init() {}
    public func pendingChangeCount() async -> Int { 0 }
    public func syncNow() async throws -> SyncReport { await demoDelay(0.5); return SyncReport() }
}

/// Body scale provider that reads from the demo dataset.
public struct DemoBodyScaleProvider: BodyScaleProvider {
    private let repository: DemoRepository
    public init(repository: DemoRepository) { self.repository = repository }
    public var id: String { "bodyscale:demo" }
    public var displayName: String { "Demo smart scale" }
    public func measurements(since: Date) async throws -> [BodyMeasurement] {
        try await repository.bodyMeasurements(from: LocalDate(since), to: .today()).filter { $0.measuredAt >= since }
    }
}
