import Foundation
import CoreModels

/// Deterministic PRNG for demo data.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func double(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }
    public mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// A small USDA-like catalog (values per 100 g, rounded from FDC SR Legacy) for demo mode.
public enum DemoFoodCatalog {
    static func f(_ id: String, _ name: String, _ kcal: Double, _ p: Double, _ c: Double, _ fat: Double, fiber: Double = 0,
                  sugar: Double = 0, sodium: Double = 0, portion: (String, Double)? = nil, brand: String? = nil,
                  db: FoodDatabaseID = .usda, density: Double? = nil) -> FoodDetail {
        FoodDetail(foodRef: FoodRef(db: db, id: id), name: name, brand: brand,
                   nutrientsPer100g: Nutrients(kcal: kcal, proteinG: p, carbsG: c, fatG: fat, fiberG: fiber, sugarG: sugar, sodiumMg: sodium),
                   portions: portion.map { [FoodPortion(label: $0.0, grams: $0.1)] } ?? [], dataType: db == .usda ? "SR Legacy" : nil,
                   densityGPerMl: density)
    }

    public static let foods: [FoodDetail] = [
        f("171477", "Chicken breast, grilled", 165, 31, 0, 3.6, sodium: 74, portion: ("1 breast", 172)),
        f("169757", "White rice, cooked", 130, 2.7, 28.2, 0.3, fiber: 0.4, sodium: 1, portion: ("1 cup", 158)),
        f("168880", "Brown rice, cooked", 123, 2.7, 25.6, 1.0, fiber: 1.6, sodium: 4, portion: ("1 cup", 195)),
        f("173944", "Rolled oats, dry", 379, 13.2, 67.7, 6.5, fiber: 10.1, sugar: 1, sodium: 6, portion: ("1/2 cup", 40)),
        f("171287", "Egg, whole, cooked", 155, 12.6, 1.1, 10.6, sugar: 1.1, sodium: 124, portion: ("1 large", 50)),
        f("170903", "Greek yogurt, plain, nonfat", 59, 10.2, 3.6, 0.4, sugar: 3.2, sodium: 36, portion: ("1 container", 170)),
        f("173946", "Blueberries", 57, 0.7, 14.5, 0.3, fiber: 2.4, sugar: 10, sodium: 1, portion: ("1 cup", 148)),
        f("173944b", "Banana", 89, 1.1, 22.8, 0.3, fiber: 2.6, sugar: 12.2, sodium: 1, portion: ("1 medium", 118)),
        f("171705", "Avocado", 160, 2, 8.5, 14.7, fiber: 6.7, sugar: 0.7, sodium: 7, portion: ("1/2 fruit", 68)),
        f("175167", "Salmon, Atlantic, baked", 206, 22.1, 0, 12.4, sodium: 61, portion: ("1 fillet", 154)),
        f("174032", "Beef, lean ground, cooked", 250, 26, 0, 15, sodium: 72),
        f("170567", "Sweet potato, baked", 90, 2, 20.7, 0.2, fiber: 3.3, sugar: 6.5, sodium: 36, portion: ("1 medium", 114)),
        f("170093", "Broccoli, steamed", 35, 2.4, 7.2, 0.4, fiber: 3.3, sugar: 1.4, sodium: 41, portion: ("1 cup", 156)),
        f("168462", "Spinach, raw", 23, 2.9, 3.6, 0.4, fiber: 2.2, sugar: 0.4, sodium: 79),
        f("169998", "Pasta, cooked", 158, 5.8, 30.9, 0.9, fiber: 1.8, sugar: 0.6, sodium: 1, portion: ("1 cup", 140)),
        f("168873", "Whole wheat bread", 252, 12.5, 42.7, 3.5, fiber: 6, sugar: 4.4, sodium: 450, portion: ("1 slice", 32)),
        f("172470", "Almonds", 579, 21.2, 21.6, 49.9, fiber: 12.5, sugar: 4.4, sodium: 1, portion: ("1 oz", 28)),
        f("172430", "Peanut butter", 588, 25, 20, 50, fiber: 6, sugar: 9, sodium: 459, portion: ("2 tbsp", 32)),
        f("170148", "Olive oil", 884, 0, 0, 100, portion: ("1 tbsp", 13.5), density: 0.91),
        f("171265", "Milk, 2%", 50, 3.3, 4.8, 2, sugar: 5.1, sodium: 47, portion: ("1 cup", 244), density: 1.03),
        f("173410", "Cheddar cheese", 403, 22.9, 3.1, 33.3, sugar: 0.5, sodium: 653, portion: ("1 slice", 28)),
        f("168411", "Tofu, firm", 144, 17.3, 2.8, 8.7, fiber: 2.3, sodium: 14),
        f("175302", "Black beans, cooked", 132, 8.9, 23.7, 0.5, fiber: 8.7, sodium: 1, portion: ("1/2 cup", 86)),
        f("169414", "Quinoa, cooked", 120, 4.4, 21.3, 1.9, fiber: 2.8, sugar: 0.9, sodium: 7, portion: ("1 cup", 185)),
        f("170457", "Tomato", 18, 0.9, 3.9, 0.2, fiber: 1.2, sugar: 2.6, sodium: 5, portion: ("1 medium", 123)),
        f("169383", "Mixed salad greens", 17, 1.5, 3.3, 0.2, fiber: 2, sugar: 1, sodium: 30),
        f("171413", "Apple", 52, 0.3, 13.8, 0.2, fiber: 2.4, sugar: 10.4, sodium: 1, portion: ("1 medium", 182)),
        f("174270", "Turkey sandwich", 218, 13.9, 23.5, 7.5, fiber: 2.2, sugar: 3.6, sodium: 760, portion: ("1 sandwich", 220)),
        f("174688", "Pizza, cheese", 266, 11.4, 33.3, 9.7, fiber: 2.3, sugar: 3.6, sodium: 598, portion: ("1 slice", 107)),
        f("171019", "Dark chocolate 70%", 598, 7.8, 45.9, 42.6, fiber: 10.9, sugar: 24, sodium: 20, portion: ("2 squares", 20)),
        f("173757", "Hummus", 166, 7.9, 14.3, 9.6, fiber: 6, sugar: 0.3, sodium: 379, portion: ("2 tbsp", 30)),
        f("171688", "Orange juice", 45, 0.7, 10.4, 0.2, fiber: 0.2, sugar: 8.4, sodium: 1, portion: ("1 cup", 248), density: 1.04),
        f("171890", "Coffee, black", 1, 0.1, 0, 0, sodium: 2, portion: ("1 cup", 240), density: 1),
        f("173180", "Latte with whole milk", 56, 3, 4.5, 3, sugar: 4.5, sodium: 42, portion: ("1 grande", 470), density: 1.03),
        f("p-whey", "Whey protein powder", 380, 78, 8, 5, sugar: 4, sodium: 200, portion: ("1 scoop", 31), brand: "Generic", db: .off),
        f("p-bar", "Protein bar, chocolate", 360, 33, 40, 12, fiber: 10, sugar: 3, sodium: 260, portion: ("1 bar", 60), brand: "Generic", db: .off),
        f("r-burrito", "Chicken burrito bowl", 135, 9.5, 14, 4.3, fiber: 3, sugar: 1.2, sodium: 380, portion: ("1 bowl", 510), brand: "Restaurant", db: .off),
        f("r-ramen", "Tonkotsu ramen", 110, 5.5, 12, 4.4, fiber: 0.8, sugar: 0.9, sodium: 520, portion: ("1 bowl", 650), brand: "Restaurant", db: .off),
        f("r-poke", "Salmon poke bowl", 150, 9, 18, 4.5, fiber: 1.8, sugar: 3, sodium: 410, portion: ("1 bowl", 450), brand: "Restaurant", db: .off),
    ]

    public static func food(named name: String) -> FoodDetail? {
        foods.first { $0.name.lowercased() == name.lowercased() } ?? foods.first { $0.name.lowercased().contains(name.lowercased()) }
    }

    public static func food(_ ref: FoodRef) -> FoodDetail? { foods.first { $0.foodRef == ref } }

    public static var restaurantFoods: [FoodDetail] { foods.filter { $0.brand == "Restaurant" } }

    /// Demo barcodes.
    public static let barcodes: [String: String] = [
        "0012345678905": "p-bar",
        "5000112546415": "p-whey",
        "0049000028911": "171688",
    ]
}
