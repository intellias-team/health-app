import SwiftUI
import CoreModels
import DesignSystem

@MainActor
@Observable
final class CalendarModel {
    var month = LocalDate.today().firstOfMonth
    var mealDays: Set<LocalDate> = []
    var workoutDays: Set<LocalDate> = []
    var weightDays: Set<LocalDate> = []
    var kcalByDay: [LocalDate: Double] = [:]

    func load(_ env: AppEnvironment) async {
        let from = month, to = month.adding(days: month.daysInMonth - 1)
        let repo = env.repository
        async let meals = repo.meals(from: from, to: to)
        async let workouts = repo.workouts(from: from, to: to)
        async let body = repo.bodyMeasurements(from: from, to: to)
        let m = (try? await meals) ?? [], w = (try? await workouts) ?? [], b = (try? await body) ?? []
        mealDays = Set(m.map(\.date))
        kcalByDay = Dictionary(grouping: m, by: \.date).mapValues { $0.reduce(0) { $0 + $1.totals.kcal } }
        workoutDays = Set(w.map { LocalDate($0.start) })
        weightDays = Set(b.filter { $0.weightKg != nil }.map { LocalDate($0.measuredAt) })
    }
}

/// Month grid. Tap any date for everything logged and measured that day.
struct CalendarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model = CalendarModel()

    private let weekdays = ["M", "T", "W", "T", "F", "S", "S"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                header
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                        Text(d).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(0..<(model.month.isoWeekday - 1), id: \.self) { _ in Color.clear.frame(height: 52) }
                    ForEach(0..<model.month.daysInMonth, id: \.self) { offset in
                        let day = model.month.adding(days: offset)
                        NavigationLink {
                            DayDetailView(date: day)
                        } label: {
                            DayCell(day: day,
                                    hasMeals: model.mealDays.contains(day),
                                    hasWorkout: model.workoutDays.contains(day),
                                    hasWeight: model.weightDays.contains(day),
                                    kcal: model.kcalByDay[day])
                        }
                        .buttonStyle(.plain)
                        .disabled(day > .today())
                    }
                }
                legend
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle("Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .task(id: "\(model.month.iso)-\(env.dataVersion)") { await model.load(env) }
    }

    private var header: some View {
        HStack {
            Button { model.month = model.month.addingMonths(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous month")
            Spacer()
            Text(model.month.startDate().formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
            Spacer()
            Button { model.month = model.month.addingMonths(1) } label: { Image(systemName: "chevron.right") }
                .disabled(model.month >= LocalDate.today().firstOfMonth)
                .accessibilityLabel("Next month")
        }
    }

    private var legend: some View {
        HStack(spacing: Spacing.l) {
            legendItem(.fuel, "Food")
            legendItem(.train, "Workout")
            legendItem(.body, "Weight")
        }
        .font(.caption).foregroundStyle(.secondary)
    }

    private func legendItem(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 7, height: 7); Text(t) }
    }
}

private struct DayCell: View {
    let day: LocalDate
    let hasMeals: Bool
    let hasWorkout: Bool
    let hasWeight: Bool
    let kcal: Double?

    var body: some View {
        let isToday = day == .today()
        VStack(spacing: 3) {
            Text("\(day.day)")
                .font(.subheadline.weight(isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.recover : (day > .today() ? Color.textTertiary : .primary))
            HStack(spacing: 3) {
                if hasMeals { Circle().fill(Color.fuel).frame(width: 5, height: 5) }
                if hasWorkout { Circle().fill(Color.train).frame(width: 5, height: 5) }
                if hasWeight { Circle().fill(Color.body).frame(width: 5, height: 5) }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(isToday ? Color.recover.opacity(0.12) : Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.startDate().formatted(date: .complete, time: .omitted))
        .accessibilityValue([hasMeals ? "food logged\(kcal.map { ", \(Int($0)) kilocalories" } ?? "")" : nil,
                             hasWorkout ? "workout" : nil, hasWeight ? "weight recorded" : nil].compactMap { $0 }.joined(separator: ", "))
    }
}
