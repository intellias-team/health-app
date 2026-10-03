import XCTest
@testable import AnalyticsKit
import CoreModels
import MockData

final class AnalyticsKitTests: XCTestCase {
    let day = LocalDate(year: 2026, month: 10, day: 3)

    private func meal(kcal: Double, protein: Double = 0, estimate: Bool = false) -> Meal {
        Meal(date: day, category: .lunch, source: estimate ? .photo : .scale,
             items: [FoodItem(name: "x", grams: 100, weightSource: estimate ? .estimated : .scale, nutrients: Nutrients(kcal: kcal, proteinG: protein))])
    }

    // MARK: Energy balance

    func testEnergyBalanceKeepsComponentsSeparate() {
        let metrics = MetricValues(activeKcal: 650, restingKcal: 1700)
        let b = EnergyBalanceCalculator.balance(metrics: metrics, meals: [meal(kcal: 800), meal(kcal: 700, estimate: true)])
        XCTAssertEqual(b.restingKcal, 1700)
        XCTAssertEqual(b.activeKcal, 650)
        XCTAssertEqual(b.totalExpenditureKcal, 2350)
        XCTAssertEqual(b.intakeKcal, 1500)
        XCTAssertEqual(b.balanceKcal, -850)
        XCTAssertTrue(b.intakeIsEstimate)
        XCTAssertFalse(b.restingIsEstimated)
    }

    func testEnergyBalanceFallbackResting() {
        let b = EnergyBalanceCalculator.balance(metrics: MetricValues(activeKcal: 300), meals: [], fallbackRestingKcal: 1600)
        XCTAssertEqual(b.restingKcal, 1600)
        XCTAssertTrue(b.restingIsEstimated)
        XCTAssertEqual(EnergyBalanceCalculator.mifflinStJeor(weightKg: 70, heightCm: 175, age: 30, sex: .male), 1648.75, accuracy: 0.01)
    }

    func testDeletedMealsExcluded() {
        var m = meal(kcal: 500)
        m.deleted = true
        XCTAssertEqual(EnergyBalanceCalculator.balance(metrics: MetricValues(), meals: [m]).intakeKcal, 0)
    }

    // MARK: Fueling insight

    func testLowIntakeHighActivityProducesNeutralMessage() throws {
        let b = EnergyBalance(restingKcal: 1700, activeKcal: 1100, intakeKcal: 1200)
        let insight = try XCTUnwrap(FuelingInsightEngine.evaluate(balance: b, trainingLoad: 150, readiness: 62, dayProgress: 1, mealsLogged: 3))
        XCTAssertEqual(insight.kind, .lowIntakeHighActivity)
        XCTAssertFalse(FuelingInsightEngine.containsForbiddenWording(insight.title + " " + insight.message), insight.message)
        XCTAssertTrue(insight.message.lowercased().contains("recover"))
        XCTAssertTrue(insight.message.contains("readiness"))
    }

    func testNoPraiseInAnyFuelingVariant() {
        var messages: [String] = []
        for intake in stride(from: 0.0, through: 3000, by: 250) {
            for active in [0.0, 300, 600, 1200] {
                for readiness in [nil, 50.0, 90] as [Double?] {
                    for logged in [0, 1, 4] {
                        let b = EnergyBalance(restingKcal: 1650, activeKcal: active, intakeKcal: intake)
                        if let i = FuelingInsightEngine.evaluate(balance: b, trainingLoad: active / 8, readiness: readiness, dayProgress: 1, mealsLogged: logged) {
                            messages.append(i.title + " " + i.message)
                        }
                    }
                }
            }
        }
        XCTAssertFalse(messages.isEmpty)
        for m in messages { XCTAssertFalse(FuelingInsightEngine.containsForbiddenWording(m), m) }
    }

    func testNoInsightEarlyInDayOrWhenFed() {
        let low = EnergyBalance(restingKcal: 1700, activeKcal: 1100, intakeKcal: 400)
        XCTAssertNil(FuelingInsightEngine.evaluate(balance: low, trainingLoad: 150, readiness: 80, dayProgress: 0.3, mealsLogged: 1))
        let fed = EnergyBalance(restingKcal: 1700, activeKcal: 900, intakeKcal: 2500)
        XCTAssertNil(FuelingInsightEngine.evaluate(balance: fed, trainingLoad: 150, readiness: 80, dayProgress: 1, mealsLogged: 4))
    }

    func testForbiddenWordDetector() {
        XCTAssertTrue(FuelingInsightEngine.containsForbiddenWording("Great job staying in a deficit!"))
        XCTAssertTrue(FuelingInsightEngine.containsForbiddenWording("Congratulations"))
        XCTAssertFalse(FuelingInsightEngine.containsForbiddenWording("Window of recovery"), "whole-word match for 'win'")
    }

    // MARK: Statistics

    func testPearson() throws {
        XCTAssertEqual(try XCTUnwrap(Stats.pearson([1, 2, 3, 4, 5], [2, 4, 6, 8, 10])), 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Stats.pearson([1, 2, 3, 4, 5], [10, 8, 6, 4, 2])), -1, accuracy: 1e-9)
        // Hand-computed: Σdxdy = 8, Σdx² = Σdy² = 10 → r = 0.8.
        XCTAssertEqual(try XCTUnwrap(Stats.pearson([1, 2, 3, 4, 5], [2, 1, 4, 3, 5])), 0.8, accuracy: 1e-9)
        XCTAssertNil(Stats.pearson([1, 2], [1, 2]), "n < 3")
        XCTAssertNil(Stats.pearson([1, 1, 1], [1, 2, 3]), "zero variance")
    }

    func testRollingAverageSkipsMissingDays() {
        let pts = [TrendPoint(date: day, value: 80), TrendPoint(date: day.adding(days: 1), value: 82),
                   TrendPoint(date: day.adding(days: 5), value: 78), TrendPoint(date: day.adding(days: 9), value: 76)]
        let r = Stats.rollingAverage(pts, windowDays: 7)
        XCTAssertEqual(r.map(\.value), [80, 81, (80.0 + 82 + 78) / 3, (78.0 + 76) / 2] as [Double])
    }

    func testSummaryAndSlope() throws {
        let pts = (0..<10).map { TrendPoint(date: day.adding(days: $0), value: 80 - 0.1 * Double($0)) }
        let s = Stats.summary(pts)
        XCTAssertEqual(try XCTUnwrap(s.delta), -0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(Stats.slopePerDay(pts)), -0.1, accuracy: 1e-9)
    }

    func testCorrelationPairsWithLag() {
        let x = (0..<5).map { TrendPoint(date: day.adding(days: $0), value: Double($0)) }
        let y = (0..<5).map { TrendPoint(date: day.adding(days: $0), value: Double($0) * 10) }
        let pairs = CorrelationAnalyzer.pairs(x: x, y: y, lagDays: 1)
        XCTAssertEqual(pairs.count, 4)
        XCTAssertEqual(pairs.first?.y, 10)
        let r = CorrelationAnalyzer.compare(xMetric: .proteinG, yMetric: .readinessScore, x: x, y: y, lagDays: 1)
        XCTAssertTrue(r.caveat.contains("Correlation is not causation"))
        XCTAssertEqual(r.n, 4)
    }

    // MARK: Training load

    func testTrimp() {
        // 60 min at HRr 0.5 (avg 125, rest 60, max 190): 60 × 0.5 × 0.64·e^(0.96) ≈ 50.15
        XCTAssertEqual(TrainingLoad.trimp(durationMin: 60, avgHr: 125, restingHr: 60, maxHr: 190, sex: .male), 50.15, accuracy: 0.05)
        XCTAssertEqual(TrainingLoad.trimp(durationMin: 60, avgHr: 125, restingHr: 60, maxHr: 190, sex: .female), 60 * 0.5 * 0.86 * exp(1.67 * 0.5), accuracy: 1e-9)
        XCTAssertEqual(TrainingLoad.trimp(durationMin: 0, avgHr: 150, restingHr: 60, maxHr: 190), 0)
    }

    func testWorkoutLoadFallbacksAndAcuteChronic() {
        let s = day.startDate()
        let explicit = Workout(start: s, end: s.addingTimeInterval(3600), type: "running", source: .healthkit, load: 77)
        XCTAssertEqual(TrainingLoad.load(for: explicit), 77)
        let noHr = Workout(start: s, end: s.addingTimeInterval(1800), type: "yoga", source: .healthkit)
        XCTAssertGreaterThan(TrainingLoad.load(for: noHr), 0)
        XCTAssertLessThan(TrainingLoad.load(for: noHr), TrainingLoad.load(for: Workout(start: s, end: s.addingTimeInterval(1800), type: "hiit", source: .healthkit)))

        var loads: [LocalDate: Double] = [:]
        for i in 0..<28 { loads[day.adding(days: -i)] = 50 }
        let steady = TrainingLoad.acuteChronic(dailyLoads: loads, on: day)
        XCTAssertEqual(steady.ratio ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(steady.status, .steady)
        for i in 0..<7 { loads[day.adding(days: -i)] = 120 }
        XCTAssertEqual(TrainingLoad.acuteChronic(dailyLoads: loads, on: day).status, .elevated)
    }

    // MARK: Merge & composition

    func testMetricMergerPrecedence() {
        let hk = MetricValues(steps: 9000, restingHr: 58, hrvMs: 40, hrvMethod: "sdnn", sleepMinutes: 400)
        let oura = MetricValues(steps: 8700, restingHr: 52, restingHrMethod: "sleepLowest", hrvMs: 60, hrvMethod: "rmssd", sleepMinutes: 420, readinessScore: 81)
        let merged = MetricMerger.merge([.healthkit: hk, .oura: oura])
        XCTAssertEqual(merged.steps, 9000, "HealthKit wins steps")
        XCTAssertEqual(merged.hrvMs, 60, "Oura wins HRV")
        XCTAssertEqual(merged.hrvMethod, "rmssd", "method travels with the value")
        XCTAssertEqual(merged.sleepMinutes, 420)
        XCTAssertEqual(merged.readinessScore, 81)

        var settings = DataSourceSettings()
        settings.precedence[.hrvMs] = [.healthkit, .oura]
        XCTAssertEqual(MetricMerger.merge([.healthkit: hk, .oura: oura], settings: settings).hrvMs, 40)
        settings.setEnabled(false, provider: "oura", metric: MetricKey.sleepMinutes.rawValue, allMetrics: DataSourceDescriptor.oura.metrics)
        XCTAssertEqual(MetricMerger.merge([.healthkit: hk, .oura: oura], settings: settings).sleepMinutes, 400, "disabled Oura metric falls back")
    }

    func testDailyBalanceFromDemoData() throws {
        let data = DemoDataProvider.generate(today: day, days: 40, now: day.startDate().addingTimeInterval(21 * 3600))
        let merged = MetricMerger.merge(days: data.dailyMetrics)
        XCTAssertEqual(merged.count, 40)
        let todayMetrics = try XCTUnwrap(merged.last).merged
        let meals = data.meals.filter { $0.date == day }
        let summary = DaySummary(date: day, meals: meals, workouts: data.workouts.filter { LocalDate($0.start) == day }, metrics: todayMetrics)
        let balance = DailyBalanceComposer.compose(summary: summary, history: merged, workouts: data.workouts, goals: data.goals, dayProgress: 1)
        XCTAssertEqual(balance.fuel.energy.intakeKcal, meals.reduce(0) { $0 + $1.totals.kcal }, accuracy: 0.001)
        XCTAssertNotNil(balance.recover.hrvBaselineMs)
        XCTAssertFalse(balance.headline.isEmpty)
        XCTAssertFalse(FuelingInsightEngine.containsForbiddenWording(balance.headline))
    }

    func testTrendBuilderWeekly() {
        let data = DemoDataProvider.generate(today: day, days: 90)
        let inputs = TrendInputs(days: MetricMerger.merge(days: data.dailyMetrics), meals: data.meals, body: data.body, workouts: data.workouts)
        let daily = TrendBuilder.series(.weight, range: .quarter, endingOn: day, inputs: inputs)
        XCTAssertGreaterThan(daily.points.count, 50)
        let yearly = TrendBuilder.series(.steps, range: .year, endingOn: day, inputs: inputs)
        XCTAssertLessThanOrEqual(yearly.points.count, 14, "weekly aggregation")
        let protein = TrendBuilder.series(.proteinG, range: .week, endingOn: day, inputs: inputs)
        XCTAssertNotNil(protein.avg)
    }
}
