import Foundation
import CoreModels

/// Pure nutrition math. Nutrients are always derived from a database entry × grams.
public enum NutritionCalculator {
    /// Nutrients for `grams` of a food with `per100g` nutrients.
    public static func nutrients(per100g: Nutrients, grams: Double) -> Nutrients {
        per100g.scaled(by: max(0, grams) / 100)
    }

    /// Rescales an item's nutrients (and range) to a new gram amount, preserving the per-gram ratio.
    /// Used when the user drags the portion slider or a scale reading replaces an estimate.
    public static func rescale(_ item: FoodItem, toGrams newGrams: Double) -> FoodItem {
        var copy = item
        guard item.grams > 0 else { copy.grams = newGrams; return copy }
        let factor = max(0, newGrams) / item.grams
        copy.nutrients = item.nutrients.scaled(by: factor)
        if let range = item.range {
            copy.range = NutrientRange(kcalLow: range.kcalLow * factor, kcalHigh: range.kcalHigh * factor)
        }
        copy.grams = newGrams
        return copy
    }

    /// kcal range for an estimate whose grams could be anywhere in `gramsLow…gramsHigh`.
    public static func kcalRange(per100g: Nutrients, gramsLow: Double, gramsHigh: Double) -> NutrientRange {
        NutrientRange(kcalLow: per100g.kcal * gramsLow / 100, kcalHigh: per100g.kcal * gramsHigh / 100)
    }

    /// Default relative uncertainty for an eyeballed portion when no model range is available (±25 %).
    public static let defaultEstimateUncertainty = 0.25

    public static func estimatedRange(kcal: Double, uncertainty: Double = defaultEstimateUncertainty) -> NutrientRange {
        NutrientRange(kcalLow: kcal * (1 - uncertainty), kcalHigh: kcal * (1 + uncertainty))
    }

    public static func totals(_ items: [FoodItem]) -> Nutrients { items.reduce(.zero) { $0 + $1.nutrients } }

    /// Creates an exact item from a database food and a measured or user-entered weight.
    public static func item(from food: FoodDetail, grams: Double, weightSource: WeightSource) -> FoodItem {
        let n = nutrients(per100g: food.nutrientsPer100g, grams: grams)
        let range: NutrientRange = weightSource == .estimated ? estimatedRange(kcal: n.kcal) : .exact(n.kcal)
        return FoodItem(name: food.brand.map { "\(food.name) (\($0))" } ?? food.name, foodRef: food.foodRef, grams: grams,
                        weightSource: weightSource, confidence: nil, nutrients: n, range: range)
    }

    /// Per-serving item from a recipe/saved meal, scaled by `servings`.
    public static func items(from recipe: Recipe, servings: Double) -> [FoodItem] {
        let factor = servings / max(recipe.servings, 1)
        return recipe.items.map { item in
            var scaled = rescale(item, toGrams: item.grams * factor)
            scaled.id = UUID().uuidString.lowercased()
            return scaled
        }
    }

    /// Percentage of energy from protein / carbs / fat (Atwater 4/4/9).
    public static func macroEnergySplit(_ n: Nutrients) -> (protein: Double, carbs: Double, fat: Double) {
        let p = n.proteinG * 4, c = n.carbsG * 4, f = n.fatG * 9
        let total = p + c + f
        guard total > 0 else { return (0, 0, 0) }
        return (p / total, c / total, f / total)
    }
}
