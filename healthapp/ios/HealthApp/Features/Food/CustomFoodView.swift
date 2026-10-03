import SwiftUI
import CoreModels
import NutritionKit
import DesignSystem

/// Create a custom food from a nutrition label (per serving or per 100 g), optionally logging it right away.
struct CustomFoodView: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var name = ""
    @State private var brand = ""
    @State private var servingG: Double = 100
    @State private var perServing = true
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var fiber: Double = 0
    @State private var sugar: Double = 0
    @State private var sodium: Double = 0
    @State private var logNow = true
    @State private var error: String?

    private var per100: Nutrients {
        let factor = perServing ? 100 / max(servingG, 1) : 1
        return Nutrients(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat, fiberG: fiber, sugarG: sugar, sodiumMg: sodium).scaled(by: factor)
    }

    var body: some View {
        Form {
            Section("Food") {
                TextField("Name", text: $name)
                TextField("Brand (optional)", text: $brand)
                LabeledContent("Serving size") {
                    TextField("g", value: $servingG, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    Text("g")
                }
            }
            Section {
                Picker("Values are", selection: $perServing) {
                    Text("Per serving").tag(true)
                    Text("Per 100 g").tag(false)
                }
                .pickerStyle(.segmented)
                field("Calories", $kcal, "kcal")
                field("Protein", $protein, "g")
                field("Carbohydrates", $carbs, "g")
                field("Fat", $fat, "g")
                field("Fiber", $fiber, "g")
                field("Sugar", $sugar, "g")
                field("Sodium", $sodium, "mg")
            } header: { Text("Nutrition label") }
            Section {
                Toggle("Log one serving now", isOn: $logNow)
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Custom food")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(name.isEmpty || kcal <= 0)
            }
        }
    }

    private func field(_ label: String, _ value: Binding<Double>, _ unit: String) -> some View {
        LabeledContent(label) {
            TextField("0", value: value, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func save() async {
        let food = CustomFood(name: name, brand: brand.isEmpty ? nil : brand, servingG: servingG, nutrientsPer100g: per100)
        do {
            let saved = try await env.nutrition.saveCustomFood(food)
            if logNow {
                let item = DraftItem(food: saved.asDetail, grams: saved.servingG, weightSource: .label).toFoodItem()
                try await env.saveMeal(Meal(date: context.date, category: context.category, source: .custom, items: [item]))
            }
            Haptics.success()
            finish()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Calories/macros only — for when you know the numbers (or an approximation).
struct QuickAddView: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var name = "Quick add"
    @State private var kcal: Double = 0
    @State private var protein: Double = 0
    @State private var carbs: Double = 0
    @State private var fat: Double = 0
    @State private var isEstimate = true

    var body: some View {
        Form {
            TextField("Description", text: $name)
            LabeledContent("Calories") { TextField("kcal", value: $kcal, format: .number).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
            LabeledContent("Protein (g)") { TextField("0", value: $protein, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Carbs (g)") { TextField("0", value: $carbs, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            LabeledContent("Fat (g)") { TextField("0", value: $fat, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
            Toggle("This is an estimate", isOn: $isEstimate)
        }
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let n = Nutrients(kcal: kcal, proteinG: protein, carbsG: carbs, fatG: fat)
                        // Quick-add items carry a nominal 100 g portion so per-100 g math stays consistent when edited.
                        let item = FoodItem(name: name, grams: 100, weightSource: isEstimate ? .estimated : .user, nutrients: n,
                                            range: isEstimate ? NutritionCalculator.estimatedRange(kcal: kcal) : .exact(kcal))
                        try? await env.saveMeal(Meal(date: context.date, category: context.category, source: .manual, items: [item]))
                        Haptics.success()
                        finish()
                    }
                }
                .disabled(kcal <= 0)
            }
        }
    }
}

/// Restaurant meals: search known dishes, or enter an estimate. Always stored as an estimate with a range.
struct RestaurantMealView: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void
    @State private var draft: MealDraft?

    var body: some View {
        FoodPickerView(restaurantOnly: true) { item in
            var estimate = item
            // Restaurant portions are never weighed by the user: keep it an estimate with ±25 % range.
            if estimate.weightSource != .scale {
                estimate.weightSource = .estimated
                estimate.lowFactor = 1 - NutritionCalculator.defaultEstimateUncertainty
                estimate.highFactor = 1 + NutritionCalculator.defaultEstimateUncertainty
            }
            draft = MealDraft(date: context.date, category: context.category, source: .restaurant, items: [estimate], notes: "Restaurant")
        }
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                QuickAddView(context: context, finish: finish)
            } label: {
                Label("Can't find it? Enter an estimate", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding()
            .background(.bar)
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm", onSaved: finish)
        }
    }
}
