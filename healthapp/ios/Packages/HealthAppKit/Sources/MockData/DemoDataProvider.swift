import Foundation
import CoreModels
import NutritionKit
import AnalyticsKit

/// Everything the demo generates.
public struct DemoDataset: Sendable {
    public var profile: Profile
    public var goals: Goals
    public var connections: [Connection]
    public var dailyMetrics: [DailyMetrics]
    public var meals: [Meal]
    public var workouts: [Workout]
    public var body: [BodyMeasurement]
    public var notes: [Note]
    public var cycle: [CycleEntry]
    public var recipes: [Recipe]
    public var customFoods: [CustomFood]
}

/// Generates 90 days of realistic, internally consistent data so every screen works without a backend,
/// HealthKit or Oura. Deterministic for a given `today` + `seed`.
public enum DemoDataProvider {
    public static func generate(today: LocalDate = .today(), days: Int = 90, seed: UInt64 = 2026, now: Date = Date(),
                                calendar: Calendar = .current) -> DemoDataset {
        var rng = SeededGenerator(seed: seed)
        let profile = Profile(displayName: "Alex", birthYear: 1991, sex: .unspecified, heightCm: 176, units: .metric,
                              timezone: calendar.timeZone.identifier, cycleTrackingEnabled: false, createdAt: today.adding(days: -days).startDate(calendar: calendar))
        let goals = Goals(calorieTarget: nil, proteinG: 140, carbsG: 260, fatG: 75, fiberG: 30, waterMl: 2500, stepGoal: 9000, sleepHours: 7.5, mode: .performance)

        var metrics: [DailyMetrics] = []
        var meals: [Meal] = []
        var workouts: [Workout] = []
        var body: [BodyMeasurement] = []
        var notes: [Note] = []
        var cycle: [CycleEntry] = []

        let hourNow = Double(calendar.component(.hour, from: now)) + Double(calendar.component(.minute, from: now)) / 60
        let start = today.adding(days: -(days - 1))
        var previousLoad = 0.0
        var weight = 78.6

        for (index, date) in LocalDate.range(from: start, through: today).enumerated() {
            let isToday = date == today
            let dayFraction = isToday ? min(1, max(0.05, (hourNow - 6) / 16)) : 1
            let weekday = date.isoWeekday // 1 Mon … 7 Sun
            let progress = Double(index) / Double(max(1, days - 1))

            // Workouts (weekly pattern with variation).
            var dayWorkouts: [Workout] = []
            func addWorkout(_ type: String, hour: Double, minutes: Double, avgHr: Double, kcalPerMin: Double, distanceKm: Double? = nil) {
                guard !isToday || hour + minutes / 60 < hourNow else { return }
                let s = date.startDate(calendar: calendar).addingTimeInterval(hour * 3600)
                let e = s.addingTimeInterval(minutes * 60)
                var w = Workout(id: "demo-w-\(date.iso)-\(type)", start: s, end: e, type: type, source: .healthkit, durationMin: minutes,
                                activeKcal: (minutes * kcalPerMin).rounded(), avgHr: avgHr.rounded(), maxHr: (avgHr + 22).rounded(),
                                distanceM: distanceKm.map { $0 * 1000 }, externalId: "HK-\(date.iso)-\(type)")
                w.load = TrainingLoad.load(for: w, restingHr: 56, maxHr: 188).rounded()
                dayWorkouts.append(w)
            }
            switch weekday {
            case 1: addWorkout("traditional_strength_training", hour: 7, minutes: rng.double(45...60), avgHr: rng.double(112...125), kcalPerMin: 6.5)
            case 2: addWorkout("running", hour: 18, minutes: rng.double(32...45), avgHr: rng.double(145...158), kcalPerMin: 11, distanceKm: rng.double(5.5...8))
            case 3: if rng.chance(0.5) { addWorkout("yoga", hour: 19, minutes: 40, avgHr: rng.double(88...98), kcalPerMin: 3.5) }
            case 4: addWorkout("high_intensity_interval_training", hour: 7, minutes: rng.double(25...35), avgHr: rng.double(150...162), kcalPerMin: 12)
            case 5: addWorkout("traditional_strength_training", hour: 18, minutes: rng.double(45...60), avgHr: rng.double(110...124), kcalPerMin: 6.5)
            case 6: addWorkout("cycling", hour: 9, minutes: rng.double(70...110), avgHr: rng.double(132...145), kcalPerMin: 9.5, distanceKm: rng.double(30...48))
            default: if rng.chance(0.4) { addWorkout("walking", hour: 11, minutes: rng.double(40...70), avgHr: rng.double(95...105), kcalPerMin: 4.5, distanceKm: rng.double(3.5...6)) }
            }
            workouts += dayWorkouts
            let load = dayWorkouts.reduce(0) { $0 + ($1.load ?? 0) }
            let workoutKcal = dayWorkouts.reduce(0) { $0 + ($1.activeKcal ?? 0) }

            // Sleep & recovery (previous night) — influenced by yesterday's load.
            let sleepMin = (rng.double(380...490) + (weekday >= 6 ? 25 : 0)).rounded()
            let deep = (sleepMin * rng.double(0.13...0.20)).rounded()
            let rem = (sleepMin * rng.double(0.19...0.25)).rounded()
            let core = sleepMin - deep - rem
            let awake = rng.double(18...45).rounded()
            let sleepScore = min(96, max(52, (55 + (sleepMin - 360) / 4 + rng.double(-6...6)).rounded()))
            let hrv = max(28, (52 + 8 * progress - previousLoad / 18 + (sleepMin - 430) / 20 + rng.double(-6...6)).rounded())
            let rhr = (57 - 2 * progress + previousLoad / 70 + rng.double(-2...2)).rounded()
            let readiness = min(97, max(48, (0.5 * sleepScore + 0.8 * hrv - 0.3 * previousLoad / 2 + rng.double(-4...4)).rounded()))
            let baseSteps = rng.double(5500...10500) + (weekday == 7 ? 2500 : 0) + dayWorkouts.reduce(0) { $0 + ($1.distanceM ?? 0) / 0.8 } * (dayWorkouts.first?.type == "cycling" ? 0 : 1)
            let steps = (baseSteps * dayFraction).rounded()
            let resting = (1690 + rng.double(-25...25)) * dayFraction
            let active = (steps * 0.035 + workoutKcal).rounded()

            var hk = MetricValues(steps: steps, activeKcal: active, restingKcal: resting.rounded(), restingHr: rhr + 1,
                                  hrvMs: max(20, hrv - 8), hrvMethod: "sdnn", sleepMinutes: sleepMin - rng.double(0...10).rounded(),
                                  sleepStages: SleepStages(coreMin: core, deepMin: deep, remMin: rem, awakeMin: awake, inBedMin: sleepMin + awake),
                                  respiratoryRate: (rng.double(13.8...15.6) * 10).rounded() / 10,
                                  waterMl: (rng.double(1600...2800) * dayFraction).rounded(),
                                  vo2max: (44 + 2 * progress).rounded())
            hk.tempDeviationC = (rng.double(-0.3...0.35) * 100).rounded() / 100
            metrics.append(DailyMetrics(date: date, source: .healthkit, metrics: hk))
            let oura = MetricValues(steps: (steps * 0.96).rounded(), activeKcal: (active * 0.92).rounded(), restingHr: rhr, restingHrMethod: "sleepLowest",
                                    hrvMs: hrv, hrvMethod: "rmssd", sleepMinutes: sleepMin,
                                    sleepStages: SleepStages(coreMin: core, deepMin: deep, remMin: rem, awakeMin: awake),
                                    sleepScore: sleepScore, readinessScore: readiness,
                                    activityScore: min(98, max(40, (60 + steps / 400 + load / 8).rounded())),
                                    tempDeviationC: (rng.double(-0.25...0.3) * 100).rounded() / 100,
                                    respiratoryRate: (rng.double(13.5...15.5) * 10).rounded() / 10,
                                    spo2Pct: (rng.double(95.5...98.5) * 10).rounded() / 10)
            metrics.append(DailyMetrics(date: date, source: .oura, metrics: oura))
            previousLoad = load

            // Meals.
            let lowFuelDay = (index % 17 == 9) // occasional under-fuelled heavy day → neutral fueling insight
            meals += makeMeals(date: date, isToday: isToday, hourNow: hourNow, heavy: load > 90, lowFuel: lowFuelDay, rng: &rng, calendar: calendar)

            // Body (most mornings) with a gentle downward weight trend.
            weight += rng.double(-0.22...0.18) - 0.004
            if rng.chance(0.8) && (!isToday || hourNow > 7.5) {
                let bf = 21.5 - 1.4 * progress + rng.double(-0.4...0.4)
                let w = (weight * 10).rounded() / 10
                body.append(BodyMeasurement(id: "demo-b-\(date.iso)", measuredAt: date.startDate(calendar: calendar).addingTimeInterval(7 * 3600 + 5 * 60),
                                            source: "bodyscale:demo", weightKg: w, bodyFatPct: (bf * 10).rounded() / 10,
                                            muscleMassKg: ((w * (1 - bf / 100) * 0.53) * 10).rounded() / 10,
                                            leanMassKg: ((w * (1 - bf / 100)) * 10).rounded() / 10,
                                            bmi: ((w / (1.76 * 1.76)) * 10).rounded() / 10, waterPct: (55 + rng.double(-1...1)).rounded(), boneMassKg: 3.2))
            }
            if index % 6 == 2 {
                let texts = ["Felt strong today.", "Late dinner with friends.", "Busy work day, short on sleep.", "Legs sore after the ride.", "Travel day."]
                notes.append(Note(date: date, text: texts[index % texts.count], tags: index % 2 == 0 ? ["work"] : ["training"]))
            }
            let cycleDay = (index + 11) % 28 + 1
            cycle.append(CycleEntry(date: date, flow: cycleDay <= 5 ? "medium" : nil, phase: cycleDay <= 5 ? "menstrual" : (cycleDay <= 13 ? "follicular" : (cycleDay <= 16 ? "ovulatory" : "luteal")), cycleDay: cycleDay))
        }

        let connections = [
            Connection(provider: "healthkit", status: .connected, enabledMetrics: HealthMetricType.allCases.map(\.rawValue), lastSyncAt: now),
            Connection(provider: "oura", status: .connected, scopes: ["daily", "heartrate", "workout", "session", "spo2"], enabledMetrics: DataSourceDescriptor.oura.metrics, lastSyncAt: now.addingTimeInterval(-1800)),
            Connection(provider: "bodyscale:demo", status: .connected, enabledMetrics: DataSourceDescriptor.bodyScale.metrics, lastSyncAt: now.addingTimeInterval(-3 * 3600)),
        ]
        return DemoDataset(profile: profile, goals: goals, connections: connections, dailyMetrics: metrics, meals: meals, workouts: workouts,
                           body: body, notes: notes, cycle: cycle, recipes: demoRecipes(), customFoods: demoCustomFoods())
    }

    // MARK: Meals

    private static func item(_ name: String, grams: Double, source: WeightSource, confidence: Double? = nil, rng: inout SeededGenerator) -> FoodItem? {
        guard let food = DemoFoodCatalog.food(named: name) else { return nil }
        var item = NutritionCalculator.item(from: food, grams: grams.rounded(), weightSource: source)
        item.name = food.name
        item.confidence = confidence
        if source == .estimated {
            let spread = 0.15 + (1 - (confidence ?? 0.7)) * 0.4
            item.range = NutrientRange(kcalLow: (item.nutrients.kcal * (1 - spread)).rounded(), kcalHigh: (item.nutrients.kcal * (1 + spread)).rounded())
        }
        item.nutrients = item.nutrients.rounded
        return item
    }

    private static func makeMeals(date: LocalDate, isToday: Bool, hourNow: Double, heavy: Bool, lowFuel: Bool,
                                  rng: inout SeededGenerator, calendar: Calendar) -> [Meal] {
        var out: [Meal] = []
        func meal(_ category: MealCategory, hour: Double, source: MealSource, _ items: [FoodItem?], notes: String? = nil) {
            guard !isToday || hour < hourNow else { return }
            let list = items.compactMap { $0 }
            guard !list.isEmpty else { return }
            let at = date.startDate(calendar: calendar).addingTimeInterval(hour * 3600)
            out.append(Meal(id: "demo-m-\(date.iso)-\(category.rawValue)-\(out.count)", date: date, loggedAt: at, category: category,
                            source: source, photoKey: source == .photo ? "demo/\(date.iso)-\(category.rawValue).jpg" : nil,
                            items: list, notes: notes, updatedAt: at.addingTimeInterval(60), version: 1))
        }
        let scale = 1.0 + (heavy ? 0.15 : 0) - (lowFuel ? 0.45 : 0)
        let variant = Int(rng.next() % 3)

        // Breakfast (food scale on most days).
        switch variant {
        case 0:
            meal(.breakfast, hour: 7.6, source: .scale, [item("Rolled oats", grams: 60 * scale, source: .scale, rng: &rng),
                                                         item("Blueberries", grams: rng.double(70...110), source: .scale, rng: &rng),
                                                         item("Greek yogurt", grams: 170, source: .label, rng: &rng),
                                                         item("Almonds", grams: rng.double(12...22), source: .scale, rng: &rng)])
        case 1:
            meal(.breakfast, hour: 7.9, source: .search, [item("Egg, whole", grams: 100 * scale, source: .user, rng: &rng),
                                                          item("Whole wheat bread", grams: 64, source: .label, rng: &rng),
                                                          item("Avocado", grams: rng.double(50...70), source: .scale, rng: &rng)])
        default:
            meal(.breakfast, hour: 8.1, source: .scale, [item("Greek yogurt", grams: 250 * scale, source: .scale, rng: &rng),
                                                         item("Banana", grams: rng.double(100...125), source: .scale, rng: &rng),
                                                         item("Peanut butter", grams: rng.double(15...25), source: .scale, rng: &rng)])
        }
        meal(.drink, hour: 9.5, source: .barcode, [item(rng.chance(0.6) ? "Latte with whole milk" : "Coffee, black", grams: rng.chance(0.5) ? 470 : 350, source: .label, rng: &rng)])

        // Lunch: AI photo estimate on most days.
        if rng.chance(0.15) {
            let r = DemoFoodCatalog.restaurantFoods[Int(rng.next() % UInt64(DemoFoodCatalog.restaurantFoods.count))]
            meal(.lunch, hour: 12.7, source: .restaurant, [item(r.name, grams: (r.portions.first?.grams ?? 450) * scale, source: .estimated, confidence: 0.7, rng: &rng)],
                 notes: "Restaurant meal")
        } else {
            meal(.lunch, hour: 12.6, source: .photo, [
                item("Chicken breast", grams: rng.double(120...170) * scale, source: .estimated, confidence: rng.double(0.78...0.93), rng: &rng),
                item(rng.chance(0.5) ? "White rice" : "Quinoa", grams: rng.double(150...220) * scale, source: .estimated, confidence: rng.double(0.65...0.85), rng: &rng),
                item("Broccoli", grams: rng.double(70...120), source: .estimated, confidence: rng.double(0.8...0.95), rng: &rng),
                item("Olive oil", grams: rng.double(6...12), source: .estimated, confidence: 0.45, rng: &rng),
            ])
        }

        // Snack.
        if !lowFuel {
            meal(.snack, hour: 16, source: rng.chance(0.5) ? .barcode : .search,
                 [rng.chance(0.5) ? item("Protein bar", grams: 60, source: .label, rng: &rng) : item("Apple", grams: rng.double(150...200), source: .scale, rng: &rng),
                  rng.chance(0.4) ? item("Dark chocolate", grams: 20, source: .scale, rng: &rng) : nil])
        }

        // Dinner.
        let dinnerVariant = Int(rng.next() % 4)
        switch dinnerVariant {
        case 0:
            meal(.dinner, hour: 19.4, source: .scale, [item("Salmon", grams: rng.double(140...180) * scale, source: .scale, rng: &rng),
                                                       item("Sweet potato", grams: rng.double(180...260) * scale, source: .scale, rng: &rng),
                                                       item("Spinach", grams: 60, source: .scale, rng: &rng),
                                                       item("Olive oil", grams: 10, source: .scale, rng: &rng)])
        case 1:
            meal(.dinner, hour: 19.8, source: .recipe, [item("Pasta", grams: rng.double(200...280) * scale, source: .scale, rng: &rng),
                                                        item("Beef, lean ground", grams: rng.double(110...150) * scale, source: .scale, rng: &rng),
                                                        item("Tomato", grams: 150, source: .scale, rng: &rng),
                                                        item("Cheddar", grams: 15, source: .scale, rng: &rng)])
        case 2:
            meal(.dinner, hour: 19.2, source: .photo, [item("Tofu", grams: rng.double(150...200) * scale, source: .estimated, confidence: 0.82, rng: &rng),
                                                       item("Brown rice", grams: rng.double(160...220) * scale, source: .estimated, confidence: 0.76, rng: &rng),
                                                       item("Broccoli", grams: 100, source: .estimated, confidence: 0.9, rng: &rng)])
        default:
            meal(.dinner, hour: 20.1, source: .voice, [item("Pizza", grams: rng.double(210...320) * scale, source: .estimated, confidence: 0.7, rng: &rng),
                                                       item("Mixed salad", grams: 80, source: .estimated, confidence: 0.8, rng: &rng)])
        }
        if heavy && !lowFuel {
            meal(.drink, hour: 17.5, source: .scale, [item("Whey protein", grams: 31, source: .scale, rng: &rng),
                                                      item("Milk, 2%", grams: 300, source: .scale, rng: &rng)])
        }
        return out
    }

    static func demoRecipes() -> [Recipe] {
        var rng = SeededGenerator(seed: 7)
        func it(_ n: String, _ g: Double) -> FoodItem? { item(n, grams: g, source: .scale, rng: &rng) }
        return [
            Recipe(id: "demo-r-oats", name: "Overnight oats", kind: .savedMeal,
                   items: [it("Rolled oats", 60), it("Greek yogurt", 150), it("Blueberries", 80), it("Milk, 2%", 120)].compactMap { $0 }, servings: 1),
            Recipe(id: "demo-r-bowl", name: "Chicken rice bowl", kind: .recipe,
                   items: [it("Chicken breast", 600), it("White rice", 800), it("Broccoli", 400), it("Olive oil", 30)].compactMap { $0 },
                   totalCookedWeightG: 1830, servings: 4),
            Recipe(id: "demo-r-shake", name: "Recovery shake", kind: .savedMeal,
                   items: [it("Whey protein", 31), it("Banana", 118), it("Milk, 2%", 300)].compactMap { $0 }, servings: 1),
        ]
    }

    static func demoCustomFoods() -> [CustomFood] {
        [CustomFood(id: "demo-cf-granola", name: "Homemade granola", servingG: 45,
                    nutrientsPer100g: Nutrients(kcal: 471, proteinG: 11, carbsG: 58, fatG: 22, fiberG: 7, sugarG: 18, sodiumMg: 30))]
    }
}
