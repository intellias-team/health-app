import Foundation
import CoreModels

/// How an item's quantity is labelled in the UI. Photo/voice estimates are *always* labelled "Estimate"
/// until the user weighs the food.
public enum QuantityBadge: String, Hashable, Sendable {
    case estimate = "Estimate"
    case weighed = "Weighed"
    case label = "Label"
    case entered = "Entered"
}

/// An editable food line used by every logging flow (photo, voice, scale, barcode, search) before saving.
public struct DraftItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var foodRef: FoodRef?
    public var grams: Double
    public var weightSource: WeightSource
    public var confidence: Double?
    /// Nutrients per 100 g used to recompute when grams change.
    public var per100g: Nutrients
    /// kcal range as a multiple of the point estimate (e.g. 0.72…1.33); 1…1 when measured.
    public var lowFactor: Double
    public var highFactor: Double
    /// Slider bounds.
    public var minGrams: Double
    public var maxGrams: Double
    public var alternatives: [FoodAlternative]
    public var isIncluded: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, foodRef: FoodRef?, grams: Double,
                weightSource: WeightSource, confidence: Double? = nil, per100g: Nutrients, lowFactor: Double = 1,
                highFactor: Double = 1, minGrams: Double? = nil, maxGrams: Double? = nil,
                alternatives: [FoodAlternative] = [], isIncluded: Bool = true) {
        self.id = id; self.name = name; self.foodRef = foodRef; self.grams = grams; self.weightSource = weightSource
        self.confidence = confidence; self.per100g = per100g; self.lowFactor = lowFactor; self.highFactor = highFactor
        self.minGrams = minGrams ?? 0
        self.maxGrams = maxGrams ?? max(grams * 3, 100)
        self.alternatives = alternatives; self.isIncluded = isIncluded
    }

    /// From an AI analysis item (photo or voice).
    public init(analyzed a: AnalyzedItem) {
        let per100 = a.grams > 0 ? a.nutrients.scaled(by: 100 / a.grams) : a.nutrients
        let kcal = a.nutrients.kcal
        let exact = a.weightSource == .scale
        let low = exact || kcal <= 0 ? 1 : a.range.kcalLow / kcal
        let high = exact || kcal <= 0 ? 1 : a.range.kcalHigh / kcal
        self.init(id: a.id, name: a.name, foodRef: a.foodRef, grams: a.grams, weightSource: a.weightSource,
                  confidence: a.confidence, per100g: per100, lowFactor: low, highFactor: high,
                  minGrams: 0, maxGrams: max(a.gramsHigh * 1.5, a.grams * 2, 50), alternatives: a.alternatives)
    }

    /// From a database food with a known weight (scale/label/user) or an eyeballed one.
    public init(food: FoodDetail, grams: Double, weightSource: WeightSource) {
        let estimated = weightSource == .estimated
        self.init(name: food.name, foodRef: food.foodRef, grams: grams, weightSource: weightSource, per100g: food.nutrientsPer100g,
                  lowFactor: estimated ? 1 - NutritionCalculator.defaultEstimateUncertainty : 1,
                  highFactor: estimated ? 1 + NutritionCalculator.defaultEstimateUncertainty : 1,
                  minGrams: 0, maxGrams: max(grams * 3, 300))
    }

    public var nutrients: Nutrients { NutritionCalculator.nutrients(per100g: per100g, grams: grams) }

    public var kcalRange: NutrientRange {
        let kcal = nutrients.kcal
        return weightSource.isMeasured ? .exact(kcal) : NutrientRange(kcalLow: kcal * lowFactor, kcalHigh: kcal * highFactor)
    }

    public var badge: QuantityBadge {
        switch weightSource {
        case .scale: return .weighed
        case .label: return .label
        case .user: return .entered
        case .estimated: return .estimate
        }
    }

    public var isEstimate: Bool { weightSource == .estimated }

    /// Replaces an estimate with an exact scale reading.
    public mutating func applyScaleReading(grams: Double) {
        self.grams = grams
        weightSource = .scale
        lowFactor = 1; highFactor = 1
        maxGrams = max(maxGrams, grams * 1.5)
    }

    /// Adjusting the slider keeps an estimate an estimate (only weighing makes it exact).
    public mutating func setGrams(_ g: Double) {
        grams = max(0, g)
        if grams > maxGrams { maxGrams = grams * 1.5 }
    }

    public func toFoodItem() -> FoodItem {
        let n = nutrients
        return FoodItem(id: id, name: name, foodRef: foodRef, grams: (grams * 10).rounded() / 10, weightSource: weightSource,
                        confidence: confidence, nutrients: n.rounded, range: isEstimate ? kcalRange : .exact(n.kcal.rounded()))
    }
}

/// A meal being composed/confirmed before it's saved.
public struct MealDraft: Hashable, Sendable, Identifiable {
    public var id: String { mealId }
    public var mealId: String
    public var date: LocalDate
    public var category: MealCategory
    public var source: MealSource
    public var photoKey: String?
    public var items: [DraftItem]
    public var notes: String
    /// Clarifying questions from the model ("Was the chicken cooked with oil?").
    public var questions: [String]

    public init(mealId: String = UUID().uuidString.lowercased(), date: LocalDate, category: MealCategory, source: MealSource,
                photoKey: String? = nil, items: [DraftItem] = [], notes: String = "", questions: [String] = []) {
        self.mealId = mealId; self.date = date; self.category = category; self.source = source
        self.photoKey = photoKey; self.items = items; self.notes = notes; self.questions = questions
    }

    public init(analysis: MealAnalysis, mealId: String, date: LocalDate, category: MealCategory, photoKey: String?) {
        self.init(mealId: mealId, date: date, category: category, source: .photo, photoKey: photoKey,
                  items: analysis.items.map(DraftItem.init(analyzed:)), questions: analysis.questions)
    }

    /// Re-opens an existing meal for editing.
    public init(meal: Meal) {
        let items = meal.items.map { item -> DraftItem in
            // Items without a weight (legacy quick-add) are treated as one 100 g "portion" so nutrients are preserved.
            let grams = item.grams > 0 ? item.grams : 100
            let per100 = item.nutrients.scaled(by: 100 / grams)
            let kcal = item.nutrients.kcal
            let r = item.effectiveRange
            return DraftItem(id: item.id, name: item.name, foodRef: item.foodRef, grams: grams, weightSource: item.weightSource,
                             confidence: item.confidence, per100g: per100,
                             lowFactor: kcal > 0 ? r.kcalLow / kcal : 1, highFactor: kcal > 0 ? r.kcalHigh / kcal : 1,
                             minGrams: 0, maxGrams: max(grams * 3, 100))
        }
        self.init(mealId: meal.id, date: meal.date, category: meal.category, source: meal.source, photoKey: meal.photoKey,
                  items: items, notes: meal.notes ?? "")
    }

    public var includedItems: [DraftItem] { items.filter(\.isIncluded) }
    public var totals: Nutrients { includedItems.reduce(.zero) { $0 + $1.nutrients } }
    public var totalsRange: NutrientRange { includedItems.reduce(NutrientRange.exact(0)) { $0 + $1.kcalRange } }
    public var isEstimate: Bool { includedItems.contains(where: \.isEstimate) }

    /// Builds the meal to persist. `existing` keeps version/loggedAt when editing.
    public func makeMeal(loggedAt: Date = Date(), existing: Meal? = nil) -> Meal {
        var meal = Meal(id: mealId, date: date, loggedAt: existing?.loggedAt ?? loggedAt, category: category, source: source,
                        photoKey: photoKey, items: includedItems.map { $0.toFoodItem() },
                        notes: notes.isEmpty ? nil : notes, updatedAt: Date(), version: existing?.version ?? 0)
        if let existing, existing.date != date { meal.previousDate = existing.date }
        meal.photoPinned = existing?.photoPinned
        meal.recomputeTotals()
        return meal
    }
}
