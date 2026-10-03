import SwiftUI
import VisionKit
import Vision
import CoreModels
import NutritionKit
import DesignSystem

/// Live barcode scanner using VisionKit's `DataScannerViewController` (iOS 16+, A12+ devices).
struct BarcodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce, .code128])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliver(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliver([item])
        }

        private func deliver(_ items: [RecognizedItem]) {
            guard !delivered else { return }
            for item in items {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, !payload.isEmpty {
                    delivered = true
                    onCode(payload)
                    return
                }
            }
        }
    }
}

/// Scan (or type) a barcode → look up the label nutrition → choose amount → DraftItem.
struct BarcodeLookupView: View {
    @Environment(AppEnvironment.self) private var env
    var knownGrams: Double?
    let onPick: (DraftItem) -> Void

    @State private var manualCode = ""
    @State private var food: FoodDetail?
    @State private var lookingUp = false
    @State private var notFound: String?
    @State private var scannerKey = UUID()

    var body: some View {
        Group {
            if let food {
                FoodAmountView(food: food, knownGrams: knownGrams, onPick: onPick)
            } else {
                VStack(spacing: Spacing.l) {
                    if BarcodeScannerView.isAvailable {
                        BarcodeScannerView { code in Task { await lookup(code) } }
                            .id(scannerKey)
                            .frame(height: 320)
                            .clipShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
                            .overlay { if lookingUp { ProgressView().controlSize(.large) } }
                            .accessibilityLabel("Barcode camera")
                    } else {
                        EmptyStateView(systemImage: "barcode.viewfinder", title: "Scanner unavailable",
                                       message: "Barcode scanning needs a camera (not available in the Simulator). Enter the number below.")
                    }
                    HStack {
                        TextField("Enter barcode number", text: $manualCode)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Button("Look up") { Task { await lookup(manualCode) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(manualCode.count < 8 || lookingUp)
                    }
                    if let notFound {
                        InfoBanner(title: "Not found", message: notFound, systemImage: "questionmark.circle", tint: .fuel)
                        Button("Scan again") { self.notFound = nil; scannerKey = UUID() }
                    }
                    Spacer()
                }
                .padding(Spacing.l)
            }
        }
        .navigationTitle("Barcode")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func lookup(_ code: String) async {
        let digits = code.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        lookingUp = true
        defer { lookingUp = false }
        Haptics.capture()
        do {
            if let f = try await env.nutrition.barcode(digits) {
                food = f
            } else {
                notFound = "No product for \(digits). Try searching by name or create a custom food from the label."
            }
        } catch {
            notFound = error.localizedDescription
        }
    }
}

struct BarcodeLogFlow: View {
    let context: LogContext
    let finish: () -> Void
    @State private var draft: MealDraft?

    var body: some View {
        BarcodeLookupView { item in
            draft = MealDraft(date: context.date, category: context.category, source: .barcode, items: [item])
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm", onSaved: finish)
        }
    }
}
