import SwiftUI
import CoreModels
import DesignSystem

/// Entry points into the add-food sheet.
enum AddFoodRoute: String, Identifiable, Hashable, CaseIterable {
    case menu, photo, scale, barcode, search, voice, recipes, restaurant, custom, quickAdd
    var id: String { rawValue }

    var title: String {
        switch self {
        case .menu: return "Add food"
        case .photo: return "Photo"
        case .scale: return "Food scale"
        case .barcode: return "Barcode"
        case .search: return "Search"
        case .voice: return "Voice"
        case .recipes: return "Saved meals & recipes"
        case .restaurant: return "Restaurant"
        case .custom: return "Custom food"
        case .quickAdd: return "Quick add"
        }
    }

    var systemImage: String {
        switch self {
        case .menu: return "plus"
        case .photo: return "camera.fill"
        case .scale: return "scalemass.fill"
        case .barcode: return "barcode.viewfinder"
        case .search: return "magnifyingglass"
        case .voice: return "waveform"
        case .recipes: return "book.closed.fill"
        case .restaurant: return "fork.knife.circle.fill"
        case .custom: return "square.and.pencil"
        case .quickAdd: return "bolt.fill"
        }
    }

    var subtitle: String {
        switch self {
        case .photo: return "AI estimate you can correct"
        case .scale: return "Exact grams from Bluetooth"
        case .barcode: return "Packaged food label"
        case .search: return "USDA & your foods"
        case .voice: return "Say what you ate"
        case .recipes: return "Log a saved meal"
        case .restaurant: return "Eating out"
        case .custom: return "Create your own food"
        case .quickAdd: return "Calories & macros only"
        case .menu: return ""
        }
    }
}

/// Context shared by all add-food flows.
struct LogContext: Equatable {
    var date: LocalDate
    var category: MealCategory
}

@MainActor
@Observable
final class FoodLogModel {
    var date = LocalDate.today()
    var meals: [Meal] = []
    var isLoading = false
    var error: String?

    func load(_ env: AppEnvironment) async {
        isLoading = meals.isEmpty
        defer { isLoading = false }
        do {
            meals = try await env.repository.meals(from: date, to: date)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    var totals: Nutrients { meals.reduce(.zero) { $0 + $1.totals } }
    var anyEstimate: Bool { meals.contains(where: \.isEstimate) }
    func meals(in c: MealCategory) -> [Meal] { meals.filter { $0.category == c }.sorted { $0.loggedAt < $1.loggedAt } }
}

struct FoodLogView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model = FoodLogModel()
    @State private var editing: Meal?
    @State private var showHistory = false

    var body: some View {
        @Bindable var env = env
        NavigationStack {
            List {
                Section {
                    DayStepper(date: $model.date)
                    dayTotals
                }
                ForEach(MealCategory.allCases) { category in
                    let meals = model.meals(in: category)
                    Section {
                        if meals.isEmpty {
                            Button {
                                env.pendingAddFood = .menu
                                lastCategory = category
                            } label: {
                                Label("Add \(category.displayName.lowercased())", systemImage: "plus.circle")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(meals) { meal in
                            Button { editing = meal } label: { MealRow(meal: meal) }
                                .buttonStyle(.plain)
                                .swipeActions {
                                    Button(role: .destructive) {
                                        Task { try? await env.deleteMeal(meal) }
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                    } header: {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            let kcal = meals.reduce(0) { $0 + $1.totals.kcal }
                            if kcal > 0 { Text("\(Fmt.kcal(kcal)) kcal").monospacedDigit() }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Food")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Food history")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        ForEach(AddFoodRoute.allCases.filter { $0 != .menu }) { route in
                            Button(route.title, systemImage: route.systemImage) { env.pendingAddFood = route }
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    } primaryAction: {
                        env.pendingAddFood = .menu
                    }
                    .accessibilityLabel("Add food")
                }
            }
            .sheet(item: $env.pendingAddFood) { route in
                AddFoodSheet(initialRoute: route,
                             context: LogContext(date: model.date, category: lastCategory ?? MealCategory.suggested(forHour: Calendar.current.component(.hour, from: Date()))))
            }
            .sheet(item: $editing) { meal in
                NavigationStack { MealEditorView(meal: meal) }
            }
            .sheet(isPresented: $showHistory) {
                NavigationStack { FoodHistoryView(targetDate: model.date) }
            }
            .task(id: "\(env.dataVersion)-\(model.date.iso)") { await model.load(env) }
            .refreshable { await model.load(env) }
        }
    }

    @State private var lastCategory: MealCategory?

    private var dayTotals: some View {
        let t = model.totals
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.kcal(t.kcal)).font(.metricLarge).monospacedDigit()
                Text("kcal").foregroundStyle(.secondary)
                Spacer()
                if model.anyEstimate { QuantityBadgeView(label: "Includes estimates", isExact: false) }
            }
            HStack(spacing: Spacing.l) {
                StatColumn("Protein", value: Fmt.int(t.proteinG), unit: "g", color: .protein)
                StatColumn("Carbs", value: Fmt.int(t.carbsG), unit: "g", color: .carbs)
                StatColumn("Fat", value: Fmt.int(t.fatG), unit: "g", color: .fat)
                StatColumn("Fiber", value: Fmt.int(t.fiberG), unit: "g", color: .fiber)
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

struct DayStepper: View {
    @Binding var date: LocalDate

    var body: some View {
        HStack {
            Button { date = date.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Previous day")
            Spacer()
            Text(label).font(.headline)
            Spacer()
            Button { date = date.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                .disabled(date >= .today())
                .accessibilityLabel("Next day")
        }
        .buttonStyle(.borderless)
    }

    private var label: String {
        let today = LocalDate.today()
        if date == today { return "Today" }
        if date == today.adding(days: -1) { return "Yesterday" }
        return date.startDate().formatted(.dateTime.weekday(.wide).month().day())
    }
}

struct MealRow: View {
    let meal: Meal

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: icon)
                .foregroundStyle(Color.fuel)
                .frame(width: 30, height: 30)
                .background(Color.fuel.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(meal.items.map(\.name).joined(separator: ", "))
                    .font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(meal.loggedAt.formatted(date: .omitted, time: .shortened))
                    Text("P \(Fmt.int(meal.totals.proteinG)) · C \(Fmt.int(meal.totals.carbsG)) · F \(Fmt.int(meal.totals.fatG))")
                }
                .font(.caption).foregroundStyle(.secondary)
                if meal.isEstimate {
                    QuantityBadgeView(label: "Estimate", isExact: false)
                } else if meal.items.contains(where: { $0.weightSource == .scale }) {
                    QuantityBadgeView(label: "Weighed", isExact: true)
                }
            }
            Spacer()
            KcalRangeLabel(meal.totalsRange ?? .exact(meal.totals.kcal), font: .subheadline.weight(.semibold))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the meal to edit")
    }

    private var icon: String {
        switch meal.source {
        case .photo: return "camera.fill"
        case .scale: return "scalemass.fill"
        case .barcode: return "barcode"
        case .voice: return "waveform"
        case .recipe: return "book.closed.fill"
        case .restaurant: return "fork.knife.circle"
        default: return "fork.knife"
        }
    }
}
