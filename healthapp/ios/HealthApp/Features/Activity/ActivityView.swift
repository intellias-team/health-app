import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

@MainActor
@Observable
final class ActivityModel {
    var range: TrendRange = .week
    var days: [MergedDay] = []
    var workouts: [Workout] = []
    var dailyLoads: [LocalDate: Double] = [:]
    var acuteChronic: TrainingLoad.AcuteChronic?
    var error: String?

    func load(_ env: AppEnvironment) async {
        let today = LocalDate.today()
        let from = today.adding(days: -(max(range.days, 28) + 27))
        do {
            async let d = env.repository.dailyMetrics(from: today.adding(days: -(range.days - 1)), to: today)
            async let w = env.repository.workouts(from: from, to: today)
            let (dd, ww) = try await (d, w)
            days = dd
            workouts = ww.sorted { $0.start > $1.start }
            dailyLoads = TrainingLoad.dailyLoads(ww)
            acuteChronic = TrainingLoad.acuteChronic(dailyLoads: dailyLoads, on: today)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    var loadPoints: [TrendPoint] {
        let today = LocalDate.today()
        return LocalDate.range(from: today.adding(days: -27), through: today).map { TrendPoint(date: $0, value: dailyLoads[$0] ?? 0) }
    }
}

struct ActivityView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = ActivityModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Spacing.l) {
                    PillPicker([TrendRange.week, .month], selection: $model.range) { $0.label }
                    stepsCard
                    activeEnergyCard
                    trainingLoadCard
                    workoutsCard
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.surface)
            .navigationTitle("Activity")
            .task(id: "\(env.dataVersion)-\(model.range.rawValue)") { await model.load(env) }
            .refreshable { await model.load(env) }
        }
    }

    private var stepsCard: some View {
        let points = model.days.compactMap { d in d.merged.steps.map { TrendPoint(date: d.date, value: $0) } }
        let avg = Stats.mean(points.map(\.value))
        return Card("Steps", systemImage: "shoeprints.fill", accent: .train) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.int(points.last?.value)).font(.metricLarge).monospacedDigit()
                Text("today").foregroundStyle(.secondary)
                Spacer()
                Text("avg \(Fmt.int(avg))").font(.subheadline).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(points) { p in
                    BarMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("Steps", p.value))
                        .foregroundStyle(p.value >= env.goals.stepGoal ? Color.train : Color.train.opacity(0.45))
                        .cornerRadius(4)
                }
                RuleMark(y: .value("Goal", env.goals.stepGoal))
                    .foregroundStyle(Color.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) { Text("Goal").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(height: 170)
            .accessibilityLabel("Daily steps chart")
            .accessibilityValue("Average \(Int(avg ?? 0)) steps per day, goal \(Int(env.goals.stepGoal))")
        }
    }

    private var activeEnergyCard: some View {
        let points = model.days.compactMap { d in d.merged.activeKcal.map { TrendPoint(date: d.date, value: $0) } }
        return Card("Active energy", systemImage: "flame.fill", accent: .train) {
            Chart(points) { p in
                AreaMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("kcal", p.value))
                    .foregroundStyle(LinearGradient(colors: [Color.train.opacity(0.35), Color.train.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.catmullRom)
                LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("kcal", p.value))
                    .foregroundStyle(Color.train)
                    .interpolationMethod(.catmullRom)
            }
            .frame(height: 140)
            .accessibilityLabel("Active energy chart")
            .accessibilityValue("Average \(Int(Stats.mean(points.map(\.value)) ?? 0)) kilocalories per day")
        }
    }

    private var trainingLoadCard: some View {
        let pts = model.loadPoints
        let rolling = Stats.rollingAverage(pts, windowDays: 7)
        return Card("Training load", systemImage: "chart.bar.xaxis", accent: .train) {
            if let ac = model.acuteChronic {
                HStack(spacing: Spacing.xl) {
                    StatColumn("7-day avg", value: Fmt.int(ac.acute))
                    StatColumn("28-day avg", value: Fmt.int(ac.chronic))
                    StatColumn("Ratio", value: ac.ratio.map { Fmt.one($0) } ?? "—")
                    Spacer()
                    Text(ac.status.rawValue)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.train.opacity(0.14), in: Capsule())
                        .foregroundStyle(Color.train)
                }
            }
            Chart {
                ForEach(pts) { p in
                    BarMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("Load", p.value))
                        .foregroundStyle(Color.train.opacity(0.5))
                }
                ForEach(rolling) { p in
                    LineMark(x: .value("Date", p.date.startDate(), unit: .day), y: .value("7-day avg", p.value))
                        .foregroundStyle(Color.train)
                        .interpolationMethod(.catmullRom)
                }
            }
            .frame(height: 150)
            .accessibilityLabel("Training load, last 28 days")
            .accessibilityValue(model.acuteChronic.map { "7-day average \(Int($0.acute)), 28-day average \(Int($0.chronic)), \($0.status.rawValue)" } ?? "")
            Text("Load is estimated from workout duration and heart rate (TRIMP). A ratio well above 1.3 means this week is much harder than your recent norm.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var workoutsCard: some View {
        Card("Recent workouts", systemImage: "figure.run", accent: .train) {
            if model.workouts.isEmpty {
                Text("No workouts in this period.").foregroundStyle(.secondary)
            }
            ForEach(model.workouts.prefix(10)) { w in
                VStack(alignment: .leading, spacing: 2) {
                    WorkoutRow(workout: w)
                    Text(w.start.formatted(.dateTime.weekday(.abbreviated).month().day()) + (w.distanceM.map { " · \(Fmt.one($0 / 1000)) km" } ?? "") + " · load \(Fmt.int(TrainingLoad.load(for: w)))")
                        .font(.caption2).foregroundStyle(.secondary).padding(.leading, 48)
                }
            }
        }
    }
}
