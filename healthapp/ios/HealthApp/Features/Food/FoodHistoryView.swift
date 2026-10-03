import SwiftUI
import CoreModels
import DesignSystem

/// Last 30 days of meals, searchable; "Log again" copies a meal to the target date.
struct FoodHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let targetDate: LocalDate

    @State private var meals: [Meal] = []
    @State private var query = ""
    @State private var relogged: String?

    private var filtered: [Meal] {
        let q = query.lowercased()
        return q.isEmpty ? meals : meals.filter { $0.items.contains { $0.name.lowercased().contains(q) } }
    }

    var body: some View {
        let grouped = Dictionary(grouping: filtered, by: \.date)
        List {
            ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                Section(day.startDate().formatted(.dateTime.weekday(.abbreviated).month().day())) {
                    ForEach(grouped[day] ?? []) { meal in
                        HStack {
                            MealRow(meal: meal)
                            Button {
                                Task { await relog(meal) }
                            } label: { Image(systemName: "arrow.uturn.forward.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Log again")
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Find a food")
        .navigationTitle("Food history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .overlay(alignment: .bottom) {
            if let relogged {
                Text(relogged).font(.subheadline.weight(.medium)).padding().background(.thinMaterial, in: Capsule()).padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task {
            let today = LocalDate.today()
            meals = ((try? await env.repository.meals(from: today.adding(days: -30), to: today)) ?? []).sorted { $0.loggedAt > $1.loggedAt }
        }
    }

    private func relog(_ meal: Meal) async {
        let copy = Meal(date: targetDate, category: meal.category, source: meal.source,
                        items: meal.items.map { var i = $0; i.id = UUID().uuidString.lowercased(); return i }, notes: meal.notes)
        do {
            try await env.saveMeal(copy)
            Haptics.success()
            withAnimation { relogged = "Logged again" }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { relogged = nil }
        } catch {
            relogged = error.localizedDescription
        }
    }
}
