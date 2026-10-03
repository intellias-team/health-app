import XCTest
@testable import HealthApp
import CoreModels
import AnalyticsKit
import MockData

@MainActor
final class HealthAppTests: XCTestCase {
    func testConfigFallsBackToDemoWhenIncomplete() {
        let empty = AppConfig(apiBaseURL: nil, cognitoDomain: "", cognitoClientId: "", cognitoRegion: "")
        XCTAssertFalse(empty.isComplete)
        let full = AppConfig(apiBaseURL: URL(string: "https://api.example.com"), cognitoDomain: "x.auth.eu-west-1.amazoncognito.com",
                             cognitoClientId: "abc", cognitoRegion: "eu-west-1")
        XCTAssertTrue(full.isComplete)
        // Running under XCTest always bootstraps demo mode.
        XCTAssertEqual(AppEnvironment.bootstrap().mode, .demo)
    }

    func testTodayLoadsInDemoMode() async {
        let env = AppEnvironment(demo: AppConfig(apiBaseURL: nil, cognitoDomain: "", cognitoClientId: "", cognitoRegion: ""))
        await env.loadAccount()
        let model = TodayViewModel()
        await model.load(env)
        XCTAssertNotNil(model.summary)
        XCTAssertNotNil(model.balance)
        XCTAssertFalse(model.weightPoints.isEmpty)
        for insight in model.insights where insight.kind == "fueling" {
            XCTAssertFalse(FuelingInsightEngine.containsForbiddenWording(insight.message))
        }
    }

    func testSavingAMealBumpsDataVersion() async throws {
        let env = AppEnvironment(demo: AppConfig(apiBaseURL: nil, cognitoDomain: "", cognitoClientId: "", cognitoRegion: ""))
        let before = env.dataVersion
        let item = FoodItem(name: "Apple", grams: 180, weightSource: .scale, nutrients: Nutrients(kcal: 94), range: .exact(94))
        _ = try await env.saveMeal(Meal(date: .today(), category: .snack, source: .scale, items: [item]))
        XCTAssertGreaterThan(env.dataVersion, before)
        let meals = try await env.repository.meals(from: .today(), to: .today())
        XCTAssertTrue(meals.contains { $0.items.first?.name == "Apple" })
    }

    func testHealthKitMetricFilterRespectsToggles() {
        var settings = DataSourceSettings()
        settings.setEnabled(false, provider: "healthkit", metric: HealthMetricType.steps.rawValue, allMetrics: HealthMetricType.allCases.map(\.rawValue))
        let day = DailyMetrics(date: .today(), source: .healthkit, metrics: MetricValues(steps: 9000, activeKcal: 500))
        let filtered = AppEnvironment.filter(day, settings: settings)
        XCTAssertNil(filtered.metrics.steps)
        XCTAssertEqual(filtered.metrics.activeKcal, 500)
    }
}
