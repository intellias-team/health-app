import SwiftUI
import Charts
import CoreModels
import AnalyticsKit
import DesignSystem

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = TodayViewModel()
    @State private var showCalendar = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: Spacing.l) {
                    if let balance = model.balance, let summary = model.summary {
                        FuelTrainRecoverCard(balance: balance)
                        ForEach(model.insights) { insight in
                            InfoBanner(title: insight.title, message: insight.message, systemImage: "leaf", tint: .recover)
                        }
                        DailyEnergyCard(energy: balance.fuel.energy)
                        NutritionCard(totals: summary.totals, goals: env.goals, mealCount: summary.activeMeals.count) {
                            env.pendingAddFood = .menu
                            env.selectedTab = .food
                        }
                        metricsGrid(summary: summary, balance: balance)
                        WorkoutsCard(workouts: summary.workouts)
                    } else if model.isLoading {
                        ProgressView().padding(.top, 80)
                    } else if let error = model.errorMessage {
                        EmptyStateView(systemImage: "wifi.exclamationmark", title: "Couldn't load today", message: error,
                                       actionTitle: "Retry") { Task { await model.load(env) } }
                    }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.xl)
            }
            .background(Color.surface)
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showCalendar = true } label: { Image(systemName: "calendar") }
                        .accessibilityLabel("Calendar")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showCalendar) { NavigationStack { CalendarView() } }
            .sheet(isPresented: $showSettings) { NavigationStack { SettingsView() } }
            .refreshable {
                await env.syncNow()
                await model.load(env)
            }
            .task(id: env.dataVersion) { await model.load(env) }
        }
    }

    @ViewBuilder
    private func metricsGrid(summary: DaySummary, balance: DailyBalance) -> some View {
        let m = summary.metrics
        let columns = [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)]
        SectionHeader("At a glance")
        LazyVGrid(columns: columns, spacing: Spacing.m) {
            MetricTile(title: "Calories burned", value: Fmt.kcal(balance.fuel.energy.totalExpenditureKcal), unit: "kcal",
                       caption: "Resting + active so far", systemImage: "flame.fill", accent: .train)
            MetricTile(title: "Steps", value: Fmt.int(m.steps), caption: "Goal \(Fmt.int(env.goals.stepGoal))",
                       systemImage: "shoeprints.fill", accent: .train, sparkline: model.stepsHistory)
            MetricTile(title: "Weight", value: model.latestWeightKg.map { Units.format(display(kg: $0), digits: 1) } ?? "—",
                       unit: env.profile.units == .imperial ? "lb" : "kg",
                       caption: model.weeklyWeightChange.map { "7-day avg \(Fmt.signed(display(kg: $0), digits: 1)) this week" },
                       systemImage: "scalemass.fill", accent: .body,
                       sparkline: model.weightAverage7d.suffix(14).map { display(kg: $0.value) })
            MetricTile(title: "Sleep score", value: Fmt.int(m.sleepScore), caption: Fmt.duration(minutes: m.sleepMinutes) + " asleep",
                       systemImage: "bed.double.fill", accent: .recover)
            MetricTile(title: "Readiness", value: Fmt.int(m.readinessScore), caption: balance.recover.label,
                       systemImage: "bolt.heart.fill", accent: .recover)
            MetricTile(title: "Activity score", value: Fmt.int(m.activityScore), systemImage: "figure.walk.motion", accent: .train)
            MetricTile(title: "HRV", value: Fmt.int(m.hrvMs), unit: "ms",
                       caption: balance.recover.hrvBaselineMs.map { "28-day avg \(Int($0)) ms" } ?? m.hrvMethod?.uppercased(),
                       systemImage: "waveform.path.ecg", accent: .recover)
            MetricTile(title: "Resting HR", value: Fmt.int(m.restingHr), unit: "bpm", systemImage: "heart.fill", accent: .recover)
            if let water = m.waterMl {
                MetricTile(title: "Hydration", value: Fmt.int(water), unit: "ml", caption: "Goal \(Fmt.int(env.goals.waterMl)) ml",
                           systemImage: "drop.fill", accent: .water)
            }
        }
    }

    private func display(kg: Double) -> Double { env.profile.units == .imperial ? Units.kgToLb(kg) : kg }
}

/// Resting, active, total expenditure and food intake kept as four distinct numbers.
struct DailyEnergyCard: View {
    let energy: EnergyBalance

    var body: some View {
        Card("Daily energy", systemImage: "bolt.fill", accent: .fuel) {
            VStack(spacing: Spacing.s) {
                row("Resting energy", energy.restingKcal, color: .body, note: energy.restingIsEstimated ? "Estimated" : nil)
                row("Active energy", energy.activeKcal, color: .train)
                Divider()
                row("Total energy expenditure", energy.totalExpenditureKcal, color: .primary, bold: true)
                row("Food intake", energy.intakeKcal, color: .fuel, bold: true, note: energy.intakeIsEstimate ? "Includes estimates" : nil)
            }
            EnergyBar(resting: energy.restingKcal, active: energy.activeKcal, intake: energy.intakeKcal)
                .padding(.vertical, Spacing.xs)
            Text(balanceSentence)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Factual, neutral description — never framed as a goal or achievement.
    private var balanceSentence: String {
        let diff = energy.balanceKcal
        if abs(diff) < 100 { return "Intake and expenditure are about even so far today." }
        return diff < 0
            ? "Intake is \(Fmt.kcal(-diff)) kcal below expenditure so far today."
            : "Intake is \(Fmt.kcal(diff)) kcal above expenditure so far today."
    }

    private func row(_ title: String, _ value: Double, color: Color, bold: Bool = false, note: String? = nil) -> some View {
        HStack {
            Circle().fill(color == .primary ? Color.clear : color).frame(width: 8, height: 8)
            Text(title).font(bold ? .subheadline.weight(.semibold) : .subheadline)
            if let note { Text(note).font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            Text("\(Fmt.kcal(value)) kcal").font(bold ? .metricSmall : .body).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct NutritionCard: View {
    let totals: Nutrients
    let goals: Goals
    let mealCount: Int
    let onLog: (() -> Void)?

    var body: some View {
        Card("Nutrition", systemImage: Domain.fuel.symbol, accent: .fuel,
             trailing: onLog.map { action in AnyView(Button("Log food", systemImage: "plus.circle.fill", action: action).font(.subheadline.weight(.semibold))) }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.kcal(totals.kcal)).font(.metricHero).monospacedDigit()
                Text("kcal eaten").foregroundStyle(.secondary)
                Spacer()
                Text("\(mealCount) meal\(mealCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            HStack {
                MacroRing(title: "Protein", value: totals.proteinG, goal: goals.proteinG, color: .protein)
                MacroRing(title: "Carbs", value: totals.carbsG, goal: goals.carbsG, color: .carbs)
                MacroRing(title: "Fat", value: totals.fatG, goal: goals.fatG, color: .fat)
            }
            HStack {
                Label("Fiber", systemImage: "leaf.fill").foregroundStyle(Color.fiber).font(.subheadline)
                ProgressView(value: min(1, goals.fiberG > 0 ? totals.fiberG / goals.fiberG : 0)).tint(.fiber)
                Text("\(Fmt.int(totals.fiberG)) / \(Fmt.int(goals.fiberG)) g").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

struct WorkoutsCard: View {
    let workouts: [Workout]

    var body: some View {
        Card("Today's workouts", systemImage: Domain.train.symbol, accent: .train) {
            if workouts.isEmpty {
                Text("No workouts recorded yet today.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(workouts) { w in WorkoutRow(workout: w) }
            }
        }
    }
}

struct WorkoutRow: View {
    let workout: Workout
    var body: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: WorkoutRow.symbol(for: workout.type))
                .font(.title3).foregroundStyle(Color.train)
                .frame(width: 36, height: 36)
                .background(Color.train.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.displayType).font(.subheadline.weight(.semibold))
                Text("\(workout.start.formatted(date: .omitted, time: .shortened)) · \(Fmt.duration(minutes: workout.durationMin))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let kcal = workout.activeKcal { Text("\(Fmt.kcal(kcal)) kcal").font(.subheadline).monospacedDigit() }
                if let hr = workout.avgHr { Text("avg \(Int(hr)) bpm").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func symbol(for type: String) -> String {
        let t = type.lowercased()
        if t.contains("run") { return "figure.run" }
        if t.contains("cycl") { return "figure.outdoor.cycle" }
        if t.contains("strength") { return "dumbbell.fill" }
        if t.contains("yoga") { return "figure.yoga" }
        if t.contains("walk") || t.contains("hik") { return "figure.walk" }
        if t.contains("swim") { return "figure.pool.swim" }
        if t.contains("interval") || t.contains("hiit") { return "figure.highintensity.intervaltraining" }
        return "figure.mixed.cardio"
    }
}
