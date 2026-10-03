import XCTest
@testable import CoreModels

final class CoreModelsTests: XCTestCase {
    /// docs/02 §2.2.2 example (comments stripped, elided ids filled in). DynamoDB key attributes are present
    /// and must be ignored by the client model.
    static let mealJSON = """
    {
      "PK": "USER#9f1c", "SK": "MEAL#2026-10-03#7b0e",
      "entityType": "meal", "id": "7b0e",
      "date": "2026-10-03", "loggedAt": "2026-10-03T12:41:00Z",
      "category": "lunch",
      "source": "photo",
      "photoKey": "users/9f1c/meals/7b0e.jpg",
      "items": [
        {
          "id": "a1",
          "name": "Grilled chicken breast",
          "foodRef": { "db": "usda", "id": "171477" },
          "grams": 142,
          "weightSource": "scale",
          "confidence": 0.86,
          "nutrients": { "kcal": 234, "proteinG": 44.0, "carbsG": 0, "fatG": 5.1,
                         "fiberG": 0, "sugarG": 0, "sodiumMg": 104 },
          "range": { "kcalLow": 234, "kcalHigh": 234 }
        }
      ],
      "totals": { "kcal": 612, "proteinG": 52, "carbsG": 61, "fatG": 17,
                  "fiberG": 7, "sugarG": 6, "sodiumMg": 790 },
      "totalsRange": { "kcalLow": 540, "kcalHigh": 700 },
      "isEstimate": true,
      "notes": "Restaurant: test",
      "updatedAt": "2026-10-03T12:42:10Z", "version": 3, "deleted": false,
      "GSI1PK": "USER#9f1c", "GSI1SK": "UPD#2026-10-03T12:42:10Z#meal#7b0e"
    }
    """

    func testMealDecodesDocExample() throws {
        let meal = try JSONCoding.makeDecoder().decode(Meal.self, from: Data(Self.mealJSON.utf8))
        XCTAssertEqual(meal.id, "7b0e")
        XCTAssertEqual(meal.date, LocalDate(year: 2026, month: 10, day: 3))
        XCTAssertEqual(meal.category, .lunch)
        XCTAssertEqual(meal.source, .photo)
        XCTAssertEqual(meal.items.count, 1)
        let item = meal.items[0]
        XCTAssertEqual(item.foodRef, FoodRef(db: .usda, id: "171477"))
        XCTAssertEqual(item.grams, 142)
        XCTAssertEqual(item.weightSource, .scale)
        XCTAssertEqual(item.confidence, 0.86)
        XCTAssertEqual(item.nutrients.proteinG, 44.0)
        XCTAssertEqual(item.range, NutrientRange(kcalLow: 234, kcalHigh: 234))
        // Server-provided totals are kept as-is (server recomputes them on PUT).
        XCTAssertEqual(meal.totals.kcal, 612)
        XCTAssertEqual(meal.totalsRange, NutrientRange(kcalLow: 540, kcalHigh: 700))
        XCTAssertTrue(meal.isEstimate)
        XCTAssertEqual(meal.version, 3)
        XCTAssertFalse(meal.deleted)
        XCTAssertEqual(meal.updatedAt, JSONCoding.parseISO8601("2026-10-03T12:42:10Z"))
    }

    func testMealRoundTrip() throws {
        let decoder = JSONCoding.makeDecoder()
        let original = try decoder.decode(Meal.self, from: Data(Self.mealJSON.utf8))
        let encoded = try JSONCoding.makeEncoder().encode(original)
        let again = try decoder.decode(Meal.self, from: encoded)
        XCTAssertEqual(original, again)

        // Wire format uses the documented key names and formats.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["date"] as? String, "2026-10-03")
        XCTAssertEqual(object["loggedAt"] as? String, "2026-10-03T12:41:00Z")
        XCTAssertNil(object["PK"], "DynamoDB keys are server-only")
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        let ref = try XCTUnwrap(items[0]["foodRef"] as? [String: Any])
        XCTAssertEqual(ref["db"] as? String, "usda")
        XCTAssertEqual(items[0]["weightSource"] as? String, "scale")
        let nutrients = try XCTUnwrap(items[0]["nutrients"] as? [String: Any])
        for key in ["kcal", "proteinG", "carbsG", "fatG", "fiberG", "sugarG", "sodiumMg"] { XCTAssertNotNil(nutrients[key], key) }
        let range = try XCTUnwrap(object["totalsRange"] as? [String: Any])
        XCTAssertEqual(range["kcalLow"] as? Double, 540)
    }

    func testFractionalSecondsAccepted() throws {
        let json = #"{"id":"x","date":"2026-10-03","loggedAt":"2026-10-03T12:41:00.123Z","category":"snack","items":[]}"#
        let meal = try JSONCoding.makeDecoder().decode(Meal.self, from: Data(json.utf8))
        XCTAssertEqual(meal.source, .manual)
        XCTAssertEqual(meal.version, 0)
        XCTAssertEqual(meal.loggedAt.timeIntervalSince1970, JSONCoding.parseISO8601("2026-10-03T12:41:00Z")!.timeIntervalSince1970 + 0.123, accuracy: 0.001)
    }

    func testRecomputeTotals() {
        let a = FoodItem(id: "a", name: "A", grams: 100, weightSource: .scale, nutrients: Nutrients(kcal: 100, proteinG: 10), range: .exact(100))
        let b = FoodItem(id: "b", name: "B", grams: 50, weightSource: .estimated, confidence: 0.7, nutrients: Nutrients(kcal: 200, proteinG: 5),
                         range: NutrientRange(kcalLow: 150, kcalHigh: 260))
        let meal = Meal(date: LocalDate(year: 2026, month: 1, day: 1), category: .dinner, source: .photo, items: [a, b])
        XCTAssertEqual(meal.totals.kcal, 300)
        XCTAssertEqual(meal.totals.proteinG, 15)
        XCTAssertEqual(meal.totalsRange, NutrientRange(kcalLow: 250, kcalHigh: 360))
        XCTAssertTrue(meal.isEstimate)
    }

    func testLocalDateArithmetic() {
        let d = LocalDate(year: 2024, month: 2, day: 28)
        XCTAssertEqual(d.adding(days: 1), LocalDate(year: 2024, month: 2, day: 29))
        XCTAssertEqual(d.adding(days: 2), LocalDate(year: 2024, month: 3, day: 1))
        XCTAssertEqual(LocalDate(year: 1970, month: 1, day: 1).dayNumber, 0)
        XCTAssertEqual(LocalDate(dayNumber: LocalDate(year: 2026, month: 10, day: 3).dayNumber), LocalDate(year: 2026, month: 10, day: 3))
        XCTAssertEqual(LocalDate("2026-10-03")?.iso, "2026-10-03")
        XCTAssertNil(LocalDate("2026-13-03"))
        XCTAssertEqual(LocalDate(year: 2026, month: 10, day: 3).isoWeekday, 6) // Saturday
        XCTAssertEqual(LocalDate(year: 2026, month: 1, day: 31).addingMonths(1), LocalDate(year: 2026, month: 2, day: 28))
        XCTAssertEqual(LocalDate(year: 2026, month: 2, day: 1).daysInMonth, 28)
    }

    func testSleepStagesAndMetricsDecode() throws {
        let json = #"{"date":"2026-10-02","source":"oura","metrics":{"restingHr":52,"restingHrMethod":"sleepLowest","hrvMs":61,"hrvMethod":"rmssd","sleepStages":{"coreMin":250,"deepMin":80,"remMin":95,"awakeMin":30}}}"#
        let d = try JSONCoding.makeDecoder().decode(DailyMetrics.self, from: Data(json.utf8))
        XCTAssertEqual(d.source, .oura)
        XCTAssertEqual(d.metrics.restingHrMethod, "sleepLowest")
        XCTAssertEqual(d.metrics.sleepStages?.asleepMin, 425)
        XCTAssertEqual(d.metrics.sleepStages?.napMin, 0)
    }

    func testJSONValueRoundTrip() throws {
        let note = Note(date: LocalDate(year: 2026, month: 10, day: 3), text: "hi", tags: ["a"])
        let value = try JSONValue.encode(note)
        XCTAssertEqual(value["text"]?.stringValue, "hi")
        XCTAssertEqual(try value.decode(as: Note.self), note)
    }

    func testGoalModeRawValues() throws {
        let data = try JSONCoding.makeEncoder().encode(Goals(mode: .loseGently))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"lose_gently\""))
    }
}
