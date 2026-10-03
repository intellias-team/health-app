import SwiftUI
import CoreModels
import DesignSystem

/// The add-food hub. Hosts every logging flow in one NavigationStack; each flow calls `finish` after saving.
struct AddFoodSheet: View {
    let initialRoute: AddFoodRoute
    @State var context: LogContext
    @Environment(\.dismiss) private var dismiss

    init(initialRoute: AddFoodRoute, context: LogContext) {
        self.initialRoute = initialRoute
        self._context = State(initialValue: context)
    }

    var body: some View {
        NavigationStack {
            Group {
                if initialRoute == .menu {
                    menu
                } else {
                    destination(initialRoute)
                }
            }
            .navigationDestination(for: AddFoodRoute.self) { destination($0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Card {
                    Picker("Meal", selection: $context.category) {
                        ForEach(MealCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("Date", selection: Binding(get: { context.date.startDate() },
                                                         set: { context.date = LocalDate($0) }),
                               in: ...Date(), displayedComponents: .date)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Spacing.m), GridItem(.flexible(), spacing: Spacing.m)], spacing: Spacing.m) {
                    ForEach(AddFoodRoute.allCases.filter { $0 != .menu }) { route in
                        NavigationLink(value: route) {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: route.systemImage).font(.title2).foregroundStyle(Color.fuel)
                                Text(route.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(route.subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                            .padding(Spacing.m)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .accessibilityHint(route.subtitle)
                    }
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle("Add food")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destination(_ route: AddFoodRoute) -> some View {
        let finish = { dismiss() }
        switch route {
        case .menu: menu
        case .photo: PhotoLogFlow(context: context, finish: finish)
        case .scale: ScaleLogFlow(context: context, finish: finish)
        case .barcode: BarcodeLogFlow(context: context, finish: finish)
        case .search: SearchLogFlow(context: context, finish: finish)
        case .voice: VoiceLogView(context: context, finish: finish)
        case .recipes: RecipesView(context: context, finish: finish)
        case .restaurant: RestaurantMealView(context: context, finish: finish)
        case .custom: CustomFoodView(context: context, finish: finish)
        case .quickAdd: QuickAddView(context: context, finish: finish)
        }
    }
}

/// Shared confirm/correct step used by every flow: edit names, grams (slider), include/exclude, weigh items on
/// the scale, see confidence and kcal ranges. Photo/voice estimates stay labelled "Estimate" until weighed.
struct ConfirmItemsView: View {
    @Environment(AppEnvironment.self) private var env
    @State var draft: MealDraft
    var existing: Meal?
    var title = "Review"
    let onSaved: () -> Void

    @State private var isSaving = false
    @State private var error: String?
    @State private var addingFood = false

    var body: some View {
        List {
            if !draft.questions.isEmpty {
                Section {
                    ForEach(draft.questions, id: \.self) { q in
                        Label(q, systemImage: "questionmark.bubble").font(.subheadline)
                    }
                } footer: { Text("Add details in notes or adjust items below — it improves the estimate.") }
            }
            Section {
                ForEach($draft.items) { $item in
                    DraftItemEditor(item: $item)
                }
                .onDelete { draft.items.remove(atOffsets: $0) }
                Button { addingFood = true } label: { Label("Add item", systemImage: "plus") }
            } header: {
                Text("Items")
            } footer: {
                if draft.isEstimate {
                    Text("Photo and voice amounts are estimates. Drag the slider to correct portions, or weigh items on your food scale for exact values.")
                }
            }
            Section("Meal") {
                Picker("Category", selection: $draft.category) {
                    ForEach(MealCategory.allCases) { Text($0.displayName).tag($0) }
                }
                DatePicker("Date", selection: Binding(get: { draft.date.startDate() }, set: { draft.date = LocalDate($0) }),
                           in: ...Date(), displayedComponents: .date)
                TextField("Notes (e.g. cooked in olive oil)", text: $draft.notes, axis: .vertical)
            }
            Section {
                totals
            }
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(isSaving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(draft.includedItems.isEmpty || isSaving)
            }
        }
        .sheet(isPresented: $addingFood) {
            NavigationStack {
                FoodPickerView { item in
                    draft.items.append(item)
                    addingFood = false
                }
            }
        }
    }

    private var totals: some View {
        let t = draft.totals
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Text("Total").font(.headline)
                Spacer()
                KcalRangeLabel(draft.isEstimate ? draft.totalsRange : .exact(t.kcal))
            }
            HStack(spacing: Spacing.l) {
                StatColumn("Protein", value: Fmt.int(t.proteinG), unit: "g", color: .protein)
                StatColumn("Carbs", value: Fmt.int(t.carbsG), unit: "g", color: .carbs)
                StatColumn("Fat", value: Fmt.int(t.fatG), unit: "g", color: .fat)
                StatColumn("Fiber", value: Fmt.int(t.fiberG), unit: "g", color: .fiber)
            }
            if draft.isEstimate {
                QuantityBadgeView(label: "Estimate", isExact: false)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await env.saveMeal(draft.makeMeal(existing: existing))
            Haptics.success()
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One editable line: name, grams slider, confidence, quantity badge, kcal (range).
struct DraftItemEditor: View {
    @Environment(AppEnvironment.self) private var env
    @Binding var item: DraftItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                Toggle(isOn: $item.isIncluded) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel("Include \(item.name)")
                TextField("Name", text: $item.name).font(.subheadline.weight(.semibold))
                if !item.alternatives.isEmpty {
                    Menu {
                        ForEach(item.alternatives, id: \.name) { alt in
                            Button(alt.name) { item.name = alt.name; if let ref = alt.foodRef { item.foodRef = ref } }
                        }
                    } label: { Image(systemName: "arrow.triangle.swap") }
                    .accessibilityLabel("Choose a different food")
                }
            }
            HStack(spacing: 6) {
                QuantityBadgeView(label: item.badge.rawValue, isExact: !item.isEstimate)
                if let c = item.confidence { ConfidenceBadge(c) }
                Spacer()
                KcalRangeLabel(item.kcalRange, font: .subheadline.weight(.semibold))
            }
            HStack {
                Slider(value: Binding(get: { item.grams }, set: { item.setGrams(($0).rounded()) }),
                       in: item.minGrams...max(item.maxGrams, item.minGrams + 1), step: 1)
                    .tint(item.isEstimate ? .fuel : .recover)
                    .accessibilityLabel("Portion")
                    .accessibilityValue("\(Int(item.grams)) grams")
                Text("\(Int(item.grams)) g").font(.subheadline).monospacedDigit().frame(width: 64, alignment: .trailing)
            }
            HStack {
                Text("P \(Fmt.one(item.nutrients.proteinG)) · C \(Fmt.one(item.nutrients.carbsG)) · F \(Fmt.one(item.nutrients.fatG))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if env.foodScale.state.isConnected {
                    Button {
                        if let g = env.foodScale.stableGrams {
                            item.applyScaleReading(grams: g)
                            Haptics.capture()
                        }
                    } label: {
                        Label(env.foodScale.stableGrams.map { "Use \(Int($0)) g" } ?? "Waiting for scale…", systemImage: "scalemass")
                    }
                    .font(.caption.weight(.semibold))
                    .disabled(env.foodScale.stableGrams == nil)
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(item.isIncluded ? 1 : 0.5)
    }
}

/// Edit an existing meal (every estimate stays editable after saving).
struct MealEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let meal: Meal
    @State private var confirmDelete = false
    @State private var savedAsRecipe = false

    var body: some View {
        ConfirmItemsView(draft: MealDraft(meal: meal), existing: meal, title: meal.category.displayName) { dismiss() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("Save as saved meal", systemImage: "book.closed") {
                            Task {
                                _ = try? await env.repository.saveRecipe(Recipe(name: meal.items.first?.name ?? "Saved meal", kind: .savedMeal, items: meal.items))
                                savedAsRecipe = true
                            }
                        }
                        Button("Delete meal", systemImage: "trash", role: .destructive) { confirmDelete = true }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
            .confirmationDialog("Delete this meal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task { try? await env.deleteMeal(meal); dismiss() }
                }
            }
            .alert("Saved to your meals", isPresented: $savedAsRecipe) { Button("OK") {} }
    }
}
