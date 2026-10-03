import XCTest
@testable import NutritionKit
import CoreModels

final class NutritionKitTests: XCTestCase {
    let chicken = FoodDetail(foodRef: FoodRef(db: .usda, id: "171477"), name: "Chicken breast",
                             nutrientsPer100g: Nutrients(kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6, sodiumMg: 74),
                             portions: [FoodPortion(label: "1 breast", grams: 172)])

    func testScalingPer100g() {
        let n = NutritionCalculator.nutrients(per100g: chicken.nutrientsPer100g, grams: 142)
        XCTAssertEqual(n.kcal, 234.3, accuracy: 0.001)
        XCTAssertEqual(n.proteinG, 44.02, accuracy: 0.001)
        XCTAssertEqual(n.sodiumMg, 105.08, accuracy: 0.001)
        XCTAssertEqual(NutritionCalculator.nutrients(per100g: chicken.nutrientsPer100g, grams: -5).kcal, 0)
    }

    func testRescaleKeepsRatioAndRange() {
        let item = FoodItem(name: "Rice", grams: 180, weightSource: .estimated, confidence: 0.78,
                            nutrients: Nutrients(kcal: 234, proteinG: 4.9, carbsG: 50.8), range: NutrientRange(kcalLow: 169, kcalHigh: 312))
        let r = NutritionCalculator.rescale(item, toGrams: 90)
        XCTAssertEqual(r.grams, 90)
        XCTAssertEqual(r.nutrients.kcal, 117, accuracy: 1e-9)
        XCTAssertEqual(r.nutrients.carbsG, 25.4, accuracy: 1e-9)
        XCTAssertEqual(r.range?.kcalLow ?? 0, 84.5, accuracy: 1e-9)
        XCTAssertEqual(r.range?.kcalHigh ?? 0, 156, accuracy: 1e-9)
    }

    func testRanges() {
        let r = NutritionCalculator.kcalRange(per100g: chicken.nutrientsPer100g, gramsLow: 100, gramsHigh: 200)
        XCTAssertEqual(r.kcalLow, 165); XCTAssertEqual(r.kcalHigh, 330)
        let est = NutritionCalculator.estimatedRange(kcal: 400)
        XCTAssertEqual(est.kcalLow, 300); XCTAssertEqual(est.kcalHigh, 500)
        XCTAssertTrue(NutrientRange.exact(250).isExact)
        let swapped = NutrientRange(kcalLow: 10, kcalHigh: 5)
        XCTAssertEqual(swapped.kcalLow, 5)
    }

    func testWeighedItemIsExact() {
        let item = NutritionCalculator.item(from: chicken, grams: 150, weightSource: .scale)
        XCTAssertEqual(item.range, .exact(247.5))
        XCTAssertFalse(item.isEstimate)
        let guess = NutritionCalculator.item(from: chicken, grams: 150, weightSource: .estimated)
        XCTAssertTrue(guess.isEstimate)
        XCTAssertFalse(guess.range!.isExact)
    }

    func testUnitConversion() throws {
        XCTAssertEqual(try UnitConverter.grams(amount: 1, unit: .ounce), 28.349523125, accuracy: 1e-9)
        XCTAssertEqual(try UnitConverter.grams(amount: 1, unit: .pound), 453.59237, accuracy: 1e-9)
        XCTAssertEqual(try UnitConverter.grams(amount: 2, unit: .kilogram), 2000)
        XCTAssertEqual(try UnitConverter.grams(amount: 1, unit: .cup), 236.5882365, accuracy: 1e-6)
        XCTAssertEqual(try UnitConverter.grams(amount: 1, unit: .tablespoon, densityGPerMl: 0.91), 13.4559559, accuracy: 1e-6)
        XCTAssertEqual(try UnitConverter.grams(amount: 3, unit: .teaspoon), 14.78676478125, accuracy: 1e-9)
        XCTAssertEqual(try UnitConverter.grams(amount: 2, unit: .piece, portionGrams: 50), 100)
        XCTAssertThrowsError(try UnitConverter.grams(amount: 1, unit: .serving)) { error in
            XCTAssertEqual(error as? UnitConversionError, .missingPortion(.serving))
        }
        XCTAssertEqual(try UnitConverter.amount(fromGrams: 56.69904625, unit: .ounce), 2, accuracy: 1e-9)
        XCTAssertEqual(Units.kgToLb(100), 220.462262, accuracy: 1e-6)
    }

    func testDraftFromAnalysisIsLabelledEstimate() {
        let analyzed = AnalyzedItem(id: "i1", name: "white rice, cooked", confidence: 0.78, foodRef: FoodRef(db: .usda, id: "169757"),
                                    grams: 180, gramsLow: 130, gramsHigh: 240, weightSource: .estimated,
                                    nutrients: Nutrients(kcal: 234, proteinG: 4.9, carbsG: 50.8, fatG: 0.5),
                                    range: NutrientRange(kcalLow: 169, kcalHigh: 312))
        var draft = DraftItem(analyzed: analyzed)
        XCTAssertEqual(draft.badge, .estimate)
        XCTAssertEqual(draft.kcalRange.kcalLow, 169, accuracy: 1e-9)
        XCTAssertEqual(draft.kcalRange.kcalHigh, 312, accuracy: 1e-9)

        // Moving the slider keeps it an estimate and scales the range.
        draft.setGrams(90)
        XCTAssertEqual(draft.badge, .estimate)
        XCTAssertEqual(draft.nutrients.kcal, 117, accuracy: 1e-9)
        XCTAssertEqual(draft.kcalRange.kcalLow, 84.5, accuracy: 1e-9)

        // Weighing makes it exact.
        draft.applyScaleReading(grams: 152)
        XCTAssertEqual(draft.badge, .weighed)
        XCTAssertTrue(draft.kcalRange.isExact)
        XCTAssertEqual(draft.toFoodItem().weightSource, .scale)
        XCTAssertEqual(draft.toFoodItem().grams, 152)
    }

    func testMealDraftMakesMeal() {
        let weighed = DraftItem(food: chicken, grams: 142, weightSource: .scale)
        var excluded = DraftItem(food: chicken, grams: 50, weightSource: .estimated)
        excluded.isIncluded = false
        let draft = MealDraft(date: LocalDate(year: 2026, month: 10, day: 3), category: .lunch, source: .scale, items: [weighed, excluded])
        let meal = draft.makeMeal()
        XCTAssertEqual(meal.items.count, 1)
        XCTAssertEqual(meal.totals.kcal, 234, accuracy: 0.5)
        XCTAssertFalse(meal.isEstimate)
        XCTAssertNil(meal.totalsRange)
        // Round trip editing preserves the item.
        let reopened = MealDraft(meal: meal)
        XCTAssertEqual(reopened.items.first?.badge, .weighed)
        XCTAssertEqual(reopened.totals.kcal, meal.totals.kcal, accuracy: 0.5)
        // Moving the meal to another day sends `previousDate` (docs/03 PUT /v1/meals/{id}).
        var moved = reopened
        moved.date = LocalDate(year: 2026, month: 10, day: 2)
        XCTAssertEqual(moved.makeMeal(existing: meal).previousDate, LocalDate(year: 2026, month: 10, day: 3))
        XCTAssertNil(reopened.makeMeal(existing: meal).previousDate)
    }

    func testRecipeServings() {
        let recipe = Recipe(name: "Bowl", kind: .recipe,
                            items: [NutritionCalculator.item(from: chicken, grams: 400, weightSource: .scale)], servings: 4)
        let items = NutritionCalculator.items(from: recipe, servings: 1)
        XCTAssertEqual(items[0].grams, 100, accuracy: 1e-9)
        XCTAssertEqual(items[0].nutrients.kcal, 165, accuracy: 1e-9)
        XCTAssertNotEqual(items[0].id, recipe.items[0].id)
    }

    func testMacroSplit() {
        let s = NutritionCalculator.macroEnergySplit(Nutrients(proteinG: 25, carbsG: 50, fatG: 100 / 9))
        XCTAssertEqual(s.protein, 0.25, accuracy: 1e-9)
        XCTAssertEqual(s.carbs, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.fat, 0.25, accuracy: 1e-9)
    }

    func testLocalFoodCacheOfflineSearch() async {
        let cache = LocalFoodCache()
        await cache.markUsed(chicken)
        let hits = await cache.offlineSearch("chick")
        XCTAssertEqual(hits.first?.name, "Chicken breast")
        let recent = await cache.recent
        XCTAssertEqual(recent.count, 1)
    }
}
