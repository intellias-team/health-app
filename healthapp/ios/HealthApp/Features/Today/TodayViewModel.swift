import Foundation
import Observation
import CoreModels
import AnalyticsKit

@MainActor
@Observable
final class TodayViewModel {
    var date = LocalDate.today()
    var summary: DaySummary?
    var balance: DailyBalance?
    var insights: [Insight] = []
    var weightPoints: [TrendPoint] = []
    var weightAverage7d: [TrendPoint] = []
    var latestWeightKg: Double?
    var stepsHistory: [Double] = []
    var isLoading = false
    var errorMessage: String?

    /// 0…1 share of the waking day (06:00–22:00) that has passed; 1 for past days.
    static func dayProgress(for date: LocalDate, now: Date = Date()) -> Double {
        guard date == LocalDate.today() else { return 1 }
        let hour = Double(Calendar.current.component(.hour, from: now)) + Double(Calendar.current.component(.minute, from: now)) / 60
        return min(1, max(0, (hour - 6) / 16))
    }

    func load(_ env: AppEnvironment) async {
        isLoading = summary == nil
        defer { isLoading = false }
        date = LocalDate.today()
        let repo = env.repository
        let d = date
        do {
            async let summaryTask = repo.daySummary(for: d)
            async let historyTask = repo.dailyMetrics(from: d.adding(days: -28), to: d)
            async let workoutsTask = repo.workouts(from: d.adding(days: -28), to: d)
            async let bodyTask = repo.bodyMeasurements(from: d.adding(days: -30), to: d)
            let (s, history, workouts, body) = try await (summaryTask, historyTask, workoutsTask, bodyTask)

            summary = s
            let fallbackResting = Self.estimatedResting(env: env, body: body)
            let composed = DailyBalanceComposer.compose(summary: s, history: history, workouts: workouts, goals: env.goals,
                                                        dayProgress: Self.dayProgress(for: d),
                                                        fallbackRestingKcal: fallbackResting)
            balance = composed

            // Server insights first; add the local fueling insight if the server didn't send one.
            var list = s.insights
            if let f = composed.fuelingInsight, !list.contains(where: { $0.kind == "fueling" }) { list.append(f.asInsight) }
            insights = list

            weightPoints = body.compactMap { b in b.weightKg.map { TrendPoint(date: LocalDate(b.measuredAt), value: $0) } }
                .reduce(into: [LocalDate: TrendPoint]()) { $0[$1.date] = $1 }.values.sorted { $0.date < $1.date }
            weightAverage7d = Stats.rollingAverage(weightPoints, windowDays: 7)
            latestWeightKg = s.latestWeightKg ?? weightPoints.last?.value
            stepsHistory = history.suffix(7).compactMap(\.merged.steps)
            errorMessage = nil
            await env.checkLowRecovery(s)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Mifflin-St Jeor pro-rated to the current time, used only when no source reports resting energy.
    static func estimatedResting(env: AppEnvironment, body: [BodyMeasurement]) -> Double? {
        guard let weight = body.last(where: { $0.weightKg != nil })?.weightKg, let height = env.profile.heightCm,
              let birthYear = env.profile.birthYear else { return nil }
        let age = Calendar.current.component(.year, from: Date()) - birthYear
        let daily = EnergyBalanceCalculator.mifflinStJeor(weightKg: weight, heightCm: height, age: age, sex: env.profile.sex)
        return daily * EnergyBalanceCalculator.dayFraction(at: Date())
    }

    /// Change of the 7-day average weight over the last week, if there's enough data.
    var weeklyWeightChange: Double? {
        guard let last = weightAverage7d.last,
              let weekAgo = weightAverage7d.last(where: { $0.date <= last.date.adding(days: -7) }) else { return nil }
        return last.value - weekAgo.value
    }
}
