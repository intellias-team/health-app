import SwiftUI
import CoreModels
import AnalyticsKit
import DesignSystem

/// Everything for one date: every meal, macro totals, energy, workouts, sleep, weight, activity and notes (editable).
struct DayDetailView: View {
    @Environment(AppEnvironment.self) private var env
    let date: LocalDate

    @State private var summary: DaySummary?
    @State private var noteText = ""
    @State private var noteSaved = false
    @State private var editing: Meal?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                if let s = summary {
                    DailyEnergyCard(energy: s.energyBalance ?? EnergyBalanceCalculator.balance(metrics: s.metrics, meals: s.activeMeals))
                    macros(s)
                    meals(s)
                    WorkoutsCard(workouts: s.workouts)
                    sleep(s.metrics)
                    activity(s.metrics)
                    bodyCard(s)
                    notes
                } else if let error {
                    EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load this day", message: error)
                } else {
                    ProgressView().padding(.top, 80)
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle(date.startDate().formatted(.dateTime.weekday(.wide).month().day()))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { meal in NavigationStack { MealEditorView(meal: meal) } }
        .task(id: env.dataVersion) { await load() }
    }

    private func load() async {
        do {
            let s = try await env.repository.daySummary(for: date)
            summary = s
            noteText = s.note?.text ?? ""
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func macros(_ s: DaySummary) -> some View {
        NutritionCard(totals: s.totals, goals: env.goals, mealCount: s.activeMeals.count, onLog: nil)
    }

    private func meals(_ s: DaySummary) -> some View {
        Card("Meals", systemImage: "fork.knife", accent: .fuel) {
            if s.activeMeals.isEmpty { Text("No food logged.").foregroundStyle(.secondary) }
            ForEach(s.activeMeals) { meal in
                Button { editing = meal } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(meal.category.displayName).font(.subheadline.weight(.semibold))
                            Text(meal.loggedAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            KcalRangeLabel(meal.totalsRange ?? .exact(meal.totals.kcal), font: .subheadline.weight(.semibold))
                        }
                        ForEach(meal.items) { item in
                            HStack {
                                Text(item.name).font(.caption)
                                Spacer()
                                Text("\(Int(item.grams)) g").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                QuantityBadgeView(label: item.isEstimate ? "Estimate" : (item.weightSource == .scale ? "Weighed" : item.weightSource.rawValue.capitalized),
                                                  isExact: !item.isEstimate)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private func sleep(_ m: MetricValues) -> some View {
        Card("Sleep & recovery", systemImage: "moon.zzz.fill", accent: .recover) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Spacing.m) {
                StatColumn("Asleep", value: Fmt.duration(minutes: m.sleepMinutes))
                StatColumn("Sleep score", value: Fmt.int(m.sleepScore))
                StatColumn("Readiness", value: Fmt.int(m.readinessScore))
                StatColumn("Deep", value: Fmt.duration(minutes: m.sleepStages?.deepMin))
                StatColumn("REM", value: Fmt.duration(minutes: m.sleepStages?.remMin))
                StatColumn("Core", value: Fmt.duration(minutes: m.sleepStages?.coreMin))
                StatColumn("HRV", value: Fmt.int(m.hrvMs), unit: "ms")
                StatColumn("Resting HR", value: Fmt.int(m.restingHr), unit: "bpm")
                StatColumn("Temp", value: m.tempDeviationC.map { Fmt.signed($0, digits: 2) } ?? "—", unit: "°C")
            }
        }
    }

    private func activity(_ m: MetricValues) -> some View {
        Card("Activity", systemImage: "figure.walk", accent: .train) {
            HStack(spacing: Spacing.l) {
                StatColumn("Steps", value: Fmt.int(m.steps))
                StatColumn("Active", value: Fmt.kcal(m.activeKcal), unit: "kcal")
                StatColumn("Activity score", value: Fmt.int(m.activityScore))
                StatColumn("Water", value: Fmt.int(m.waterMl), unit: "ml")
            }
        }
    }

    private func bodyCard(_ s: DaySummary) -> some View {
        Card("Body", systemImage: "scalemass.fill", accent: .body) {
            if s.body.isEmpty { Text("No measurements.").foregroundStyle(.secondary) }
            ForEach(s.body) { b in
                HStack(spacing: Spacing.l) {
                    StatColumn("Weight", value: b.weightKg.map { Units.formatWeight(kg: $0, system: env.profile.units) } ?? "—")
                    StatColumn("Body fat", value: Fmt.one(b.bodyFatPct), unit: "%")
                    StatColumn("Lean mass", value: Fmt.one(b.leanMassKg), unit: "kg")
                    Spacer()
                    Text(b.measuredAt.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notes: some View {
        Card("Notes", systemImage: "note.text", accent: .body) {
            TextField("How did today feel? Anything unusual?", text: $noteText, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                if noteSaved { Label("Saved", systemImage: "checkmark").font(.caption).foregroundStyle(Color.recover) }
                Spacer()
                Button("Save note") {
                    Task {
                        try? await env.saveNote(Note(date: date, text: noteText, tags: summary?.note?.tags ?? []))
                        noteSaved = true
                        Haptics.success()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(noteText == (summary?.note?.text ?? ""))
            }
        }
    }
}
