import Foundation

/// Nutrient totals for an item, meal or day. Matches the `nutrients` / `totals` objects in docs/02 §2.2.2.
public struct Nutrients: Codable, Hashable, Sendable {
    public var kcal: Double
    public var proteinG: Double
    public var carbsG: Double
    public var fatG: Double
    public var fiberG: Double
    public var sugarG: Double
    public var sodiumMg: Double

    public init(kcal: Double = 0, proteinG: Double = 0, carbsG: Double = 0, fatG: Double = 0,
                fiberG: Double = 0, sugarG: Double = 0, sodiumMg: Double = 0) {
        self.kcal = kcal; self.proteinG = proteinG; self.carbsG = carbsG; self.fatG = fatG
        self.fiberG = fiberG; self.sugarG = sugarG; self.sodiumMg = sodiumMg
    }

    public static let zero = Nutrients()

    private enum CodingKeys: String, CodingKey { case kcal, proteinG, carbsG, fatG, fiberG, sugarG, sodiumMg }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kcal = try c.decodeIfPresent(Double.self, forKey: .kcal) ?? 0
        proteinG = try c.decodeIfPresent(Double.self, forKey: .proteinG) ?? 0
        carbsG = try c.decodeIfPresent(Double.self, forKey: .carbsG) ?? 0
        fatG = try c.decodeIfPresent(Double.self, forKey: .fatG) ?? 0
        fiberG = try c.decodeIfPresent(Double.self, forKey: .fiberG) ?? 0
        sugarG = try c.decodeIfPresent(Double.self, forKey: .sugarG) ?? 0
        sodiumMg = try c.decodeIfPresent(Double.self, forKey: .sodiumMg) ?? 0
    }

    public static func + (lhs: Nutrients, rhs: Nutrients) -> Nutrients {
        Nutrients(kcal: lhs.kcal + rhs.kcal, proteinG: lhs.proteinG + rhs.proteinG,
                  carbsG: lhs.carbsG + rhs.carbsG, fatG: lhs.fatG + rhs.fatG,
                  fiberG: lhs.fiberG + rhs.fiberG, sugarG: lhs.sugarG + rhs.sugarG,
                  sodiumMg: lhs.sodiumMg + rhs.sodiumMg)
    }

    public static func += (lhs: inout Nutrients, rhs: Nutrients) { lhs = lhs + rhs }

    public func scaled(by factor: Double) -> Nutrients {
        Nutrients(kcal: kcal * factor, proteinG: proteinG * factor, carbsG: carbsG * factor,
                  fatG: fatG * factor, fiberG: fiberG * factor, sugarG: sugarG * factor,
                  sodiumMg: sodiumMg * factor)
    }

    /// Rounds to sensible display precision (kcal & mg to integers, grams to 0.1).
    public var rounded: Nutrients {
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return Nutrients(kcal: kcal.rounded(), proteinG: r1(proteinG), carbsG: r1(carbsG), fatG: r1(fatG),
                         fiberG: r1(fiberG), sugarG: r1(sugarG), sodiumMg: sodiumMg.rounded())
    }
}

/// Uncertainty range of an estimate's energy. `kcalLow == kcalHigh` when weighed.
public struct NutrientRange: Codable, Hashable, Sendable {
    public var kcalLow: Double
    public var kcalHigh: Double

    public init(kcalLow: Double, kcalHigh: Double) {
        self.kcalLow = min(kcalLow, kcalHigh)
        self.kcalHigh = max(kcalLow, kcalHigh)
    }

    public static func exact(_ kcal: Double) -> NutrientRange { NutrientRange(kcalLow: kcal, kcalHigh: kcal) }

    public var isExact: Bool { abs(kcalHigh - kcalLow) < 0.5 }

    public static func + (lhs: NutrientRange, rhs: NutrientRange) -> NutrientRange {
        NutrientRange(kcalLow: lhs.kcalLow + rhs.kcalLow, kcalHigh: lhs.kcalHigh + rhs.kcalHigh)
    }
}

public enum FoodDatabaseID: String, Codable, Hashable, Sendable, CaseIterable {
    case usda, off, custom, recipe, ai
}

public struct FoodRef: Codable, Hashable, Sendable {
    public var db: FoodDatabaseID
    public var id: String
    public init(db: FoodDatabaseID, id: String) { self.db = db; self.id = id }
}

/// How the grams of an item were obtained. Only `.scale` (and `.label`) are exact.
public enum WeightSource: String, Codable, Hashable, Sendable {
    case scale, estimated, user, label

    public var isMeasured: Bool { self == .scale || self == .label }
}

/// One logged food inside a meal (docs/02 §2.2.2 `items[]`).
public struct FoodItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var foodRef: FoodRef?
    public var grams: Double
    public var weightSource: WeightSource
    /// AI recognition confidence 0-1, nil for non-AI items.
    public var confidence: Double?
    public var nutrients: Nutrients
    public var range: NutrientRange?

    public init(id: String = UUID().uuidString.lowercased(), name: String, foodRef: FoodRef? = nil, grams: Double,
                weightSource: WeightSource, confidence: Double? = nil, nutrients: Nutrients, range: NutrientRange? = nil) {
        self.id = id; self.name = name; self.foodRef = foodRef; self.grams = grams
        self.weightSource = weightSource; self.confidence = confidence; self.nutrients = nutrients; self.range = range
    }

    /// True when the item's grams were estimated (by AI or by eye) rather than measured.
    public var isEstimate: Bool { weightSource == .estimated }

    /// Range to show in the UI; exact items collapse to a single value.
    public var effectiveRange: NutrientRange { range ?? .exact(nutrients.kcal) }
}

public enum MealCategory: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack, drink
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    /// A reasonable default for "now".
    public static func suggested(forHour hour: Int) -> MealCategory {
        switch hour {
        case 4..<11: return .breakfast
        case 11..<15: return .lunch
        case 17..<22: return .dinner
        default: return .snack
        }
    }
}

public enum MealSource: String, Codable, Hashable, Sendable, CaseIterable {
    case photo, scale, barcode, search, voice, recipe, restaurant, custom, manual
}

/// A meal (docs/02 §2.2.2). DynamoDB key attributes (PK/SK/GSI*) are server-only and ignored.
public struct Meal: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var date: LocalDate
    public var loggedAt: Date
    public var category: MealCategory
    public var source: MealSource
    public var photoKey: String?
    public var items: [FoodItem]
    public var totals: Nutrients
    public var totalsRange: NutrientRange?
    public var isEstimate: Bool
    public var notes: String?
    /// Set when an edit moves the meal to another day, so the server can remove the old `MEAL#<date>` item.
    public var previousDate: LocalDate?
    /// Keeps the meal photo beyond the 30-day S3 lifecycle.
    public var photoPinned: Bool?
    public var updatedAt: Date?
    public var version: Int
    public var deleted: Bool

    public init(id: String = UUID().uuidString.lowercased(), date: LocalDate, loggedAt: Date = Date(),
                category: MealCategory, source: MealSource, photoKey: String? = nil, items: [FoodItem],
                notes: String? = nil, updatedAt: Date? = nil, version: Int = 0, deleted: Bool = false) {
        self.id = id; self.date = date; self.loggedAt = loggedAt; self.category = category; self.source = source
        self.photoKey = photoKey; self.items = items; self.notes = notes; self.updatedAt = updatedAt
        self.version = version; self.deleted = deleted
        self.totals = .zero; self.totalsRange = nil; self.isEstimate = false
        recomputeTotals()
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, loggedAt, category, source, photoKey, items, totals, totalsRange, isEstimate, notes, previousDate, photoPinned, updatedAt, version, deleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(LocalDate.self, forKey: .date)
        loggedAt = try c.decode(Date.self, forKey: .loggedAt)
        category = try c.decode(MealCategory.self, forKey: .category)
        source = try c.decodeIfPresent(MealSource.self, forKey: .source) ?? .manual
        photoKey = try c.decodeIfPresent(String.self, forKey: .photoKey)
        items = try c.decodeIfPresent([FoodItem].self, forKey: .items) ?? []
        totals = try c.decodeIfPresent(Nutrients.self, forKey: .totals) ?? items.reduce(.zero) { $0 + $1.nutrients }
        totalsRange = try c.decodeIfPresent(NutrientRange.self, forKey: .totalsRange)
        isEstimate = try c.decodeIfPresent(Bool.self, forKey: .isEstimate) ?? items.contains { $0.isEstimate }
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        previousDate = try c.decodeIfPresent(LocalDate.self, forKey: .previousDate)
        photoPinned = try c.decodeIfPresent(Bool.self, forKey: .photoPinned)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }

    /// Recomputes `totals`, `totalsRange` and `isEstimate` from `items`.
    /// (The server does the same on PUT; doing it locally keeps offline UI correct.)
    public mutating func recomputeTotals() {
        totals = items.reduce(.zero) { $0 + $1.nutrients }
        let anyRange = items.contains { $0.range != nil && !($0.range!.isExact) }
        totalsRange = anyRange ? items.reduce(NutrientRange.exact(0)) { $0 + $1.effectiveRange } : nil
        isEstimate = items.contains { $0.isEstimate }
    }
}

/// Search hit returned by `/v1/foods/search`.
public struct FoodSummary: Codable, Hashable, Sendable, Identifiable {
    public var foodRef: FoodRef
    public var name: String
    public var brand: String?
    public var nutrientsPer100g: Nutrients?
    public var servingG: Double?
    public var servingLabel: String?
    public var isRestaurant: Bool?

    public var id: String { "\(foodRef.db.rawValue):\(foodRef.id)" }

    public init(foodRef: FoodRef, name: String, brand: String? = nil, nutrientsPer100g: Nutrients? = nil,
                servingG: Double? = nil, servingLabel: String? = nil, isRestaurant: Bool? = nil) {
        self.foodRef = foodRef; self.name = name; self.brand = brand; self.nutrientsPer100g = nutrientsPer100g
        self.servingG = servingG; self.servingLabel = servingLabel; self.isRestaurant = isRestaurant
    }
}

public struct FoodPortion: Codable, Hashable, Sendable {
    public var label: String
    public var grams: Double
    public init(label: String, grams: Double) { self.label = label; self.grams = grams }
}

/// Full food record from `/v1/foods/{db}/{id}` or `/v1/foods/barcode/{gtin}`.
public struct FoodDetail: Codable, Hashable, Sendable, Identifiable {
    public var foodRef: FoodRef
    public var name: String
    public var brand: String?
    public var nutrientsPer100g: Nutrients
    public var portions: [FoodPortion]
    public var dataType: String?
    /// Density for ml ↔ g conversion of liquids, if known.
    public var densityGPerMl: Double?

    public var id: String { "\(foodRef.db.rawValue):\(foodRef.id)" }

    public init(foodRef: FoodRef, name: String, brand: String? = nil, nutrientsPer100g: Nutrients,
                portions: [FoodPortion] = [], dataType: String? = nil, densityGPerMl: Double? = nil) {
        self.foodRef = foodRef; self.name = name; self.brand = brand; self.nutrientsPer100g = nutrientsPer100g
        self.portions = portions; self.dataType = dataType; self.densityGPerMl = densityGPerMl
    }

    private enum CodingKeys: String, CodingKey { case foodRef, name, brand, nutrientsPer100g, portions, dataType, densityGPerMl }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        foodRef = try c.decode(FoodRef.self, forKey: .foodRef)
        name = try c.decode(String.self, forKey: .name)
        brand = try c.decodeIfPresent(String.self, forKey: .brand)
        nutrientsPer100g = try c.decode(Nutrients.self, forKey: .nutrientsPer100g)
        portions = try c.decodeIfPresent([FoodPortion].self, forKey: .portions) ?? []
        dataType = try c.decodeIfPresent(String.self, forKey: .dataType)
        densityGPerMl = try c.decodeIfPresent(Double.self, forKey: .densityGPerMl)
    }
}

/// User-defined food (`FOOD#<id>`).
public struct CustomFood: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var brand: String?
    public var servingG: Double
    public var nutrientsPer100g: Nutrients
    public var updatedAt: Date?
    public var version: Int?

    public init(id: String = UUID().uuidString.lowercased(), name: String, brand: String? = nil, servingG: Double,
                nutrientsPer100g: Nutrients, updatedAt: Date? = nil, version: Int? = nil) {
        self.id = id; self.name = name; self.brand = brand; self.servingG = servingG
        self.nutrientsPer100g = nutrientsPer100g; self.updatedAt = updatedAt; self.version = version
    }

    public var asDetail: FoodDetail {
        FoodDetail(foodRef: FoodRef(db: .custom, id: id), name: name, brand: brand, nutrientsPer100g: nutrientsPer100g,
                   portions: [FoodPortion(label: "1 serving", grams: servingG)])
    }
}

public enum RecipeKind: String, Codable, Hashable, Sendable { case recipe, savedMeal }

/// Recipe or saved meal (`RECIPE#<id>`).
public struct Recipe: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: RecipeKind
    public var items: [FoodItem]
    public var totalCookedWeightG: Double?
    public var servings: Double
    public var updatedAt: Date?
    public var version: Int?

    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: RecipeKind, items: [FoodItem],
                totalCookedWeightG: Double? = nil, servings: Double = 1, updatedAt: Date? = nil, version: Int? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.items = items
        self.totalCookedWeightG = totalCookedWeightG; self.servings = servings; self.updatedAt = updatedAt; self.version = version
    }

    public var totals: Nutrients { items.reduce(.zero) { $0 + $1.nutrients } }
    public var perServing: Nutrients { totals.scaled(by: 1 / max(servings, 1)) }
}
