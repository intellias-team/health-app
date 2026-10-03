import Foundation

public struct FoodAlternative: Codable, Hashable, Sendable {
    public var name: String
    public var foodRef: FoodRef?
    public init(name: String, foodRef: FoodRef? = nil) { self.name = name; self.foodRef = foodRef }
}

/// One AI-recognised item (`MealAnalysis.items[]`, also `/v1/ai/voice-parse`).
/// Nutrients are computed server-side from the nutrition database × grams; the model only identifies foods
/// and estimates grams with a range.
public struct AnalyzedItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var confidence: Double
    public var foodRef: FoodRef?
    public var grams: Double
    public var gramsLow: Double
    public var gramsHigh: Double
    public var weightSource: WeightSource
    public var nutrients: Nutrients
    public var range: NutrientRange
    public var alternatives: [FoodAlternative]

    public init(id: String, name: String, confidence: Double, foodRef: FoodRef? = nil, grams: Double, gramsLow: Double,
                gramsHigh: Double, weightSource: WeightSource = .estimated, nutrients: Nutrients, range: NutrientRange,
                alternatives: [FoodAlternative] = []) {
        self.id = id; self.name = name; self.confidence = confidence; self.foodRef = foodRef; self.grams = grams
        self.gramsLow = gramsLow; self.gramsHigh = gramsHigh; self.weightSource = weightSource
        self.nutrients = nutrients; self.range = range; self.alternatives = alternatives
    }

    private enum CodingKeys: String, CodingKey { case id, name, confidence, foodRef, grams, gramsLow, gramsHigh, weightSource, nutrients, range, alternatives }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0.5
        foodRef = try c.decodeIfPresent(FoodRef.self, forKey: .foodRef)
        grams = try c.decode(Double.self, forKey: .grams)
        gramsLow = try c.decodeIfPresent(Double.self, forKey: .gramsLow) ?? grams
        gramsHigh = try c.decodeIfPresent(Double.self, forKey: .gramsHigh) ?? grams
        weightSource = try c.decodeIfPresent(WeightSource.self, forKey: .weightSource) ?? .estimated
        nutrients = try c.decode(Nutrients.self, forKey: .nutrients)
        range = try c.decodeIfPresent(NutrientRange.self, forKey: .range) ?? .exact(nutrients.kcal)
        alternatives = try c.decodeIfPresent([FoodAlternative].self, forKey: .alternatives) ?? []
    }
}

/// `POST /v1/ai/meal-analysis` response.
public struct MealAnalysis: Codable, Hashable, Sendable {
    public var analysisId: String
    public var items: [AnalyzedItem]
    public var totals: Nutrients
    public var totalsRange: NutrientRange
    public var isEstimate: Bool
    public var questions: [String]
    public var model: String?

    public init(analysisId: String, items: [AnalyzedItem], totals: Nutrients? = nil, totalsRange: NutrientRange? = nil,
                isEstimate: Bool = true, questions: [String] = [], model: String? = nil) {
        self.analysisId = analysisId; self.items = items
        self.totals = totals ?? items.reduce(.zero) { $0 + $1.nutrients }
        self.totalsRange = totalsRange ?? items.reduce(NutrientRange.exact(0)) { $0 + $1.range }
        self.isEstimate = isEstimate; self.questions = questions; self.model = model
    }

    private enum CodingKeys: String, CodingKey { case analysisId, items, totals, totalsRange, isEstimate, questions, model }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        analysisId = try c.decode(String.self, forKey: .analysisId)
        items = try c.decodeIfPresent([AnalyzedItem].self, forKey: .items) ?? []
        totals = try c.decodeIfPresent(Nutrients.self, forKey: .totals) ?? items.reduce(.zero) { $0 + $1.nutrients }
        totalsRange = try c.decodeIfPresent(NutrientRange.self, forKey: .totalsRange) ?? items.reduce(NutrientRange.exact(0)) { $0 + $1.range }
        // Photo analysis is always an estimate unless the server says otherwise.
        isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? true
        questions = try c.decodeIfPresent([String].self, forKey: .questions) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model)
    }
}

/// A food-scale reading attached to a photo analysis request.
public struct ScaleReadingInput: Codable, Hashable, Sendable {
    public var grams: Double
    public var label: String?
    public init(grams: Double, label: String? = nil) { self.grams = grams; self.label = label }
}

public struct CoachCitation: Codable, Hashable, Sendable {
    public var metric: String
    public var from: LocalDate?
    public var to: LocalDate?
    public init(metric: String, from: LocalDate? = nil, to: LocalDate? = nil) { self.metric = metric; self.from = from; self.to = to }
}

/// `POST /v1/ai/coach` response.
public struct CoachReply: Codable, Hashable, Sendable {
    public var reply: String
    public var citations: [CoachCitation]
    public var disclaimer: String?
    public init(reply: String, citations: [CoachCitation] = [], disclaimer: String? = nil) {
        self.reply = reply; self.citations = citations; self.disclaimer = disclaimer
    }
}

public struct ChatMessage: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }
    public var id: String
    public var role: Role
    public var text: String
    public var citations: [CoachCitation]
    public var createdAt: Date
    public init(id: String = UUID().uuidString, role: Role, text: String, citations: [CoachCitation] = [], createdAt: Date = Date()) {
        self.id = id; self.role = role; self.text = text; self.citations = citations; self.createdAt = createdAt
    }
}

public enum CoachCopy {
    public static let disclaimer = "HealthApp Coach offers general wellness information based on your logged data. It is not medical advice and cannot diagnose or treat any condition. Talk to a qualified professional about health concerns."

    public static let suggestedQuestions = [
        "Why am I more tired this week?",
        "How much protein have I averaged this week?",
        "Did my sleep improve compared with last month?",
        "What foods contributed the most sodium today?",
        "How did my training volume compare with last week?",
    ]
}
