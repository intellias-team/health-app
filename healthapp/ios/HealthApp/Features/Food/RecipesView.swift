import SwiftUI
import CoreModels
import NutritionKit
import DesignSystem

/// Saved meals & recipes: log with a servings stepper, or create a new one.
struct RecipesView: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var recipes: [Recipe] = []
    @State private var selected: Recipe?
    @State private var draft: MealDraft?
    @State private var creating = false

    var body: some View {
        List {
            let saved = recipes.filter { $0.kind == .savedMeal }
            let cooked = recipes.filter { $0.kind == .recipe }
            if recipes.isEmpty {
                EmptyStateView(systemImage: "book.closed", title: "Nothing saved yet",
                               message: "Save a logged meal from its editor, or create a recipe.")
            }
            if !saved.isEmpty { Section("Saved meals") { ForEach(saved) { row($0) } } }
            if !cooked.isEmpty { Section("Recipes") { ForEach(cooked) { row($0) } } }
        }
        .navigationTitle("Saved meals & recipes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { creating = true } label: { Image(systemName: "plus") }.accessibilityLabel("New recipe")
            }
        }
        .task { recipes = (try? await env.repository.recipes()) ?? [] }
        .sheet(item: $selected) { recipe in
            ServingsSheet(recipe: recipe) { servings in
                selected = nil
                let items = NutritionCalculator.items(from: recipe, servings: servings).map { item -> DraftItem in
                    let per100 = item.grams > 0 ? item.nutrients.scaled(by: 100 / item.grams) : item.nutrients
                    return DraftItem(id: item.id, name: item.name, foodRef: item.foodRef, grams: item.grams,
                                     weightSource: item.weightSource, per100g: per100)
                }
                draft = MealDraft(date: context.date, category: context.category, source: .recipe, items: items, notes: recipe.name)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $creating) {
            NavigationStack {
                RecipeEditorView { recipe in
                    recipes.append(recipe)
                    creating = false
                }
            }
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm", onSaved: finish)
        }
    }

    private func row(_ r: Recipe) -> some View {
        Button { selected = r } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name).font(.subheadline.weight(.medium))
                    Text("\(r.items.count) items · \(Fmt.kcal(r.perServing.kcal)) kcal per serving").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ServingsSheet: View {
    let recipe: Recipe
    let onLog: (Double) -> Void
    @State private var servings: Double = 1

    var body: some View {
        NavigationStack {
            Form {
                Section(recipe.name) {
                    Stepper(value: $servings, in: 0.25...20, step: 0.25) {
                        Text("\(servings.formatted(.number.precision(.fractionLength(0...2)))) serving\(servings == 1 ? "" : "s")")
                    }
                    let n = recipe.perServing.scaled(by: servings)
                    LabeledContent("Calories", value: "\(Fmt.kcal(n.kcal)) kcal")
                    LabeledContent("Protein", value: "\(Fmt.one(n.proteinG)) g")
                    if let cooked = recipe.totalCookedWeightG {
                        LabeledContent("Portion weight", value: "\(Int(cooked / max(recipe.servings, 1) * servings)) g")
                    }
                }
                Button("Log") { onLog(servings) }.frame(maxWidth: .infinity)
            }
            .navigationTitle("Servings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Create a recipe or saved meal from database foods.
struct RecipeEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let onSaved: (Recipe) -> Void

    @State private var name = ""
    @State private var kind: RecipeKind = .recipe
    @State private var servings: Double = 4
    @State private var cookedWeight: Double?
    @State private var items: [FoodItem] = []
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) {
                    Text("Recipe").tag(RecipeKind.recipe)
                    Text("Saved meal").tag(RecipeKind.savedMeal)
                }
                Stepper("Servings: \(Int(servings))", value: $servings, in: 1...50)
                TextField("Total cooked weight (g, optional)", value: $cookedWeight, format: .number).keyboardType(.decimalPad)
            }
            Section("Ingredients") {
                ForEach(items) { i in
                    LabeledContent(i.name, value: "\(Int(i.grams)) g · \(Fmt.kcal(i.nutrients.kcal)) kcal")
                }
                .onDelete { items.remove(atOffsets: $0) }
                Button("Add ingredient", systemImage: "plus") { adding = true }
            }
            if !items.isEmpty {
                Section("Per serving") {
                    let per = items.reduce(Nutrients.zero) { $0 + $1.nutrients }.scaled(by: 1 / servings)
                    LabeledContent("Calories", value: "\(Fmt.kcal(per.kcal)) kcal")
                    LabeledContent("Protein", value: "\(Fmt.one(per.proteinG)) g")
                }
            }
        }
        .navigationTitle("New recipe")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        let r = Recipe(name: name, kind: kind, items: items, totalCookedWeightG: cookedWeight, servings: servings)
                        if let saved = try? await env.repository.saveRecipe(r) { onSaved(saved) }
                    }
                }
                .disabled(name.isEmpty || items.isEmpty)
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack {
                FoodPickerView { draftItem in
                    items.append(draftItem.toFoodItem())
                    adding = false
                }
            }
        }
    }
}
