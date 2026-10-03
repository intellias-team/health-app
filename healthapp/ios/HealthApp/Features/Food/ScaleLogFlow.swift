import SwiftUI
import CoreModels
import NutritionKit
import FoodScaleKit
import DesignSystem

/// Food-scale logging: connect → live weight → tare → capture a stable weight → pick the food (search, barcode
/// or photo) → exact nutrition. Repeat for each item ("weigh, add, tare").
struct ScaleLogFlow: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var items: [DraftItem] = []
    @State private var capturedGrams: Double?
    @State private var pickMode: PickMode?
    @State private var draft: MealDraft?

    enum PickMode: String, Identifiable { case search, barcode; var id: String { rawValue } }

    var body: some View {
        let scale = env.foodScale
        List {
            Section {
                if scale.state.isConnected {
                    liveWeight(scale)
                } else {
                    connectView(scale)
                }
            }
            if !items.isEmpty {
                Section("Weighed items") {
                    ForEach(items) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name).font(.subheadline.weight(.medium))
                                Text("\(Int(item.grams)) g · P \(Fmt.one(item.nutrients.proteinG)) g").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            QuantityBadgeView(label: item.badge.rawValue, isExact: !item.isEstimate)
                            Text("\(Fmt.kcal(item.nutrients.kcal)) kcal").monospacedDigit()
                        }
                    }
                    .onDelete { items.remove(atOffsets: $0) }
                }
            }
        }
        .navigationTitle("Food scale")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Review") {
                    draft = MealDraft(date: context.date, category: context.category, source: .scale, items: items)
                }
                .disabled(items.isEmpty)
            }
        }
        .confirmationDialog("What did you weigh?", isPresented: Binding(get: { capturedGrams != nil && pickMode == nil }, set: { if !$0 && pickMode == nil { capturedGrams = nil } }),
                            titleVisibility: .visible) {
            Button("Search food") { pickMode = .search }
            Button("Scan barcode") { pickMode = .barcode }
            Button("Cancel", role: .cancel) { capturedGrams = nil }
        } message: {
            Text("\(Int(capturedGrams ?? 0)) g captured. Pick the food for exact nutrition.")
        }
        .sheet(item: $pickMode, onDismiss: { capturedGrams = nil }) { mode in
            NavigationStack {
                switch mode {
                case .search:
                    FoodPickerView(knownGrams: capturedGrams) { item in add(item) }
                case .barcode:
                    BarcodeLookupView(knownGrams: capturedGrams) { item in add(item) }
                }
            }
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm", onSaved: finish)
        }
    }

    private func add(_ item: DraftItem) {
        var exact = item
        if let g = capturedGrams { exact.applyScaleReading(grams: g) }
        items.append(exact)
        pickMode = nil
        capturedGrams = nil
        Haptics.success()
    }

    @ViewBuilder
    private func liveWeight(_ scale: FoodScaleManager) -> some View {
        VStack(spacing: Spacing.m) {
            HStack {
                Label(scale.connectedDriverName ?? "Scale", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if scale.stableGrams != nil {
                    Label("Stable", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Color.recover)
                } else {
                    Label("Settling…", systemImage: "waveform.path").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(Fmt.one(scale.latestReading?.grams ?? 0)) g")
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: scale.latestReading?.grams)
                .accessibilityLabel("Weight \(Int(scale.latestReading?.grams ?? 0)) grams, \(scale.stableGrams == nil ? "settling" : "stable")")
            HStack(spacing: Spacing.m) {
                Button { scale.tare(); Haptics.selection() } label: {
                    Label("Tare", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button {
                    guard let g = scale.stableGrams else { return }
                    Haptics.capture()
                    capturedGrams = g
                } label: {
                    Label("Capture", systemImage: "scope").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.recover)
                .disabled(scale.stableGrams == nil)
            }
            .controlSize(.large)
            if scale.simulate {
                Menu("Simulator: place an item") {
                    ForEach([85.0, 142, 210, 312.4, 450], id: \.self) { g in
                        Button("\(Int(g)) g") { scale.simulatePlacing(grams: g) }
                    }
                }
                .font(.caption)
            }
            Text("Tip: place a bowl, tap Tare, add food, wait for “Stable”, then Capture. Tare again before the next item.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, Spacing.s)
    }

    @ViewBuilder
    private func connectView(_ scale: FoodScaleManager) -> some View {
        switch scale.state {
        case .poweredOff:
            Label("Turn on Bluetooth to connect your scale.", systemImage: "bolt.horizontal.circle")
        case .unauthorized:
            Label("Allow Bluetooth access in Settings to use a food scale.", systemImage: "lock")
        case .unsupported:
            Label("Bluetooth isn't available on this device.", systemImage: "xmark.octagon")
        case .connecting(let name):
            HStack { ProgressView(); Text("Connecting to \(name)…") }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(Color.train)
            Button("Scan again") { scale.startScan() }
        default:
            if scale.discovered.isEmpty {
                HStack {
                    if scale.state == .scanning { ProgressView() }
                    Text(scale.state == .scanning ? "Looking for scales…" : "No scale connected")
                }
                Button("Scan for scales") { scale.startScan() }
            }
            ForEach(scale.discovered) { found in
                Button {
                    scale.connect(found)
                } label: {
                    HStack {
                        Image(systemName: "scalemass")
                        VStack(alignment: .leading) {
                            Text(found.name)
                            Text(found.driverName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Connect").font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
    }
}
