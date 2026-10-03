import SwiftUI
import CoreModels
import NutritionKit
import DesignSystem

/// Search the nutrition database (USDA + custom foods) and pick an amount. Calls `onPick` with a ready DraftItem.
struct FoodPickerView: View {
    @Environment(AppEnvironment.self) private var env
    var knownGrams: Double?
    var restaurantOnly = false
    let onPick: (DraftItem) -> Void

    @State private var query = ""
    @State private var results: [FoodSummary] = []
    @State private var customFoods: [CustomFood] = []
    @State private var isSearching = false
    @State private var error: String?

    var body: some View {
        List {
            if let knownGrams {
                Section {
                    Label("Weighed: \(Int(knownGrams)) g — pick the food to get exact nutrition", systemImage: "scalemass.fill")
                        .font(.subheadline).foregroundStyle(Color.recover)
                }
            }
            if query.isEmpty && !customFoods.isEmpty && !restaurantOnly {
                Section("Your foods") {
                    ForEach(customFoods) { food in
                        NavigationLink {
                            FoodAmountView(food: food.asDetail, knownGrams: knownGrams, onPick: onPick)
                        } label: { FoodSummaryRow(name: food.name, brand: food.brand, per100: food.nutrientsPer100g) }
                    }
                }
            }
            Section(query.isEmpty ? "Suggestions" : "Results") {
                if isSearching { ProgressView() }
                ForEach(results) { r in
                    NavigationLink {
                        FoodDetailLoader(ref: r.foodRef, knownGrams: knownGrams, onPick: onPick)
                    } label: { FoodSummaryRow(name: r.name, brand: r.brand, per100: r.nutrientsPer100g) }
                }
                if !isSearching && results.isEmpty && !query.isEmpty {
                    Text("No matches. Try a simpler name, or create a custom food.").foregroundStyle(.secondary)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary).font(.footnote) } }
        }
        .navigationTitle(restaurantOnly ? "Restaurant meals" : "Search food")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: restaurantOnly ? "Dish or restaurant" : "Food, brand or dish")
        .task(id: query) {
            // Debounce typing.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await search()
        }
        .task { customFoods = (try? await env.repository.customFoods()) ?? [] }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        do {
            var r = try await env.nutrition.search(query: restaurantOnly && query.isEmpty ? "restaurant" : query, limit: 25)
            if restaurantOnly { r = r.filter { $0.isRestaurant == true || $0.brand == "Restaurant" } }
            results = r
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FoodSummaryRow: View {
    let name: String
    let brand: String?
    let per100: Nutrients?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                if let brand { Text(brand) }
                if let p = per100 { Text("\(Fmt.kcal(p.kcal)) kcal · P \(Fmt.one(p.proteinG)) g per 100 g") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Loads full food detail then shows the amount picker.
struct FoodDetailLoader: View {
    @Environment(AppEnvironment.self) private var env
    let ref: FoodRef
    var knownGrams: Double?
    let onPick: (DraftItem) -> Void
    @State private var detail: FoodDetail?
    @State private var error: String?

    var body: some View {
        Group {
            if let detail {
                FoodAmountView(food: detail, knownGrams: knownGrams, onPick: onPick)
            } else if let error {
                EmptyStateView(systemImage: "exclamationmark.triangle", title: "Couldn't load food", message: error)
            } else {
                ProgressView()
            }
        }
        .task {
            do { detail = try await env.nutrition.food(ref) } catch { self.error = error.localizedDescription }
        }
    }
}

/// Choose an amount in grams, household units or label servings. A scale weight (if provided) is exact.
struct FoodAmountView: View {
    let food: FoodDetail
    var knownGrams: Double?
    let onPick: (DraftItem) -> Void

    @State private var amount: Double = 100
    @State private var unitIndex = 0
    @State private var weighed = false

    struct UnitOption: Hashable { var label: String; var unit: HouseholdUnit; var portionGrams: Double? }

    private var options: [UnitOption] {
        var o = [UnitOption(label: "g", unit: .gram, portionGrams: nil), UnitOption(label: "oz", unit: .ounce, portionGrams: nil)]
        o += food.portions.map { UnitOption(label: $0.label, unit: .serving, portionGrams: $0.grams) }
        if food.densityGPerMl != nil {
            o += [UnitOption(label: "ml", unit: .milliliter, portionGrams: nil), UnitOption(label: "cup", unit: .cup, portionGrams: nil)]
        }
        return o
    }

    private var grams: Double {
        let opt = options[min(unitIndex, options.count - 1)]
        return (try? UnitConverter.grams(amount: amount, unit: opt.unit, densityGPerMl: food.densityGPerMl ?? 1, portionGrams: opt.portionGrams)) ?? amount
    }

    private var weightSource: WeightSource {
        if weighed { return .scale }
        return options[min(unitIndex, options.count - 1)].unit == .serving ? .label : .user
    }

    var body: some View {
        let n = NutritionCalculator.nutrients(per100g: food.nutrientsPer100g, grams: grams)
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(food.name).font(.headline)
                    if let brand = food.brand { Text(brand).font(.subheadline).foregroundStyle(.secondary) }
                }
            }
            Section("Amount") {
                if weighed {
                    HStack {
                        Label("\(Int(grams)) g from scale", systemImage: "scalemass.fill").foregroundStyle(Color.recover)
                        Spacer()
                        QuantityBadgeView(label: "Weighed", isExact: true)
                    }
                    Button("Enter amount instead") { weighed = false }
                } else {
                    HStack {
                        TextField("Amount", value: $amount, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .font(.metricSmall)
                        Picker("Unit", selection: $unitIndex) {
                            ForEach(options.indices, id: \.self) { Text(options[$0].label).tag($0) }
                        }
                        .labelsHidden()
                    }
                    if unitIndex != 0 { Text("= \(Int(grams)) g").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Nutrition") {
                nutrientRow("Calories", n.kcal, "kcal")
                nutrientRow("Protein", n.proteinG, "g")
                nutrientRow("Carbs", n.carbsG, "g")
                nutrientRow("Fat", n.fatG, "g")
                nutrientRow("Fiber", n.fiberG, "g")
                nutrientRow("Sugar", n.sugarG, "g")
                nutrientRow("Sodium", n.sodiumMg, "mg")
            }
            Section {
                Button {
                    onPick(DraftItem(food: food, grams: grams, weightSource: weightSource))
                } label: {
                    Text("Add \(Int(grams)) g").frame(maxWidth: .infinity).font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .disabled(grams <= 0)
            }
        }
        .navigationTitle("Amount")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let knownGrams { amount = knownGrams; unitIndex = 0; weighed = true }
            else if !food.portions.isEmpty { amount = 1; unitIndex = 2 } // default to the first label serving
        }
    }

    private func nutrientRow(_ label: String, _ value: Double, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(unit == "kcal" || unit == "mg" ? Fmt.int(value) : Fmt.one(value)) \(unit)").monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Search → amount → confirm.
struct SearchLogFlow: View {
    let context: LogContext
    let finish: () -> Void
    @State private var draft: MealDraft?

    var body: some View {
        FoodPickerView { item in
            draft = MealDraft(date: context.date, category: context.category, source: .search, items: [item])
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, onSaved: finish)
        }
    }
}
