import SwiftUI
import PhotosUI
import UIKit
import CoreModels
import NutritionKit
import DesignSystem
import FoodRecognitionKit // ImagePreprocessor (downscale + strip EXIF/GPS)

/// Capture → analyse → confirm. Results are always presented as estimates with ranges until weighed.
struct PhotoLogFlow: View {
    @Environment(AppEnvironment.self) private var env
    let context: LogContext
    let finish: () -> Void

    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var imageData: Data?
    @State private var preview: UIImage?
    @State private var hint = ""
    @State private var includeScale = true
    @State private var isAnalyzing = false
    @State private var error: String?
    @State private var draft: MealDraft?

    private var cameraAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.l) {
                photoArea
                if !isAnalyzing {
                    HStack(spacing: Spacing.m) {
                        Button { showCamera = true } label: {
                            Label("Camera", systemImage: "camera.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!cameraAvailable)
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)

                    Card {
                        TextField("Optional hint (e.g. “cooked in butter”, “large bowl”)", text: $hint, axis: .vertical)
                        if env.foodScale.state.isConnected, let grams = env.foodScale.stableGrams {
                            Toggle(isOn: $includeScale) {
                                Label("Include scale reading: \(Int(grams)) g", systemImage: "scalemass.fill")
                            }
                            .tint(.recover)
                        }
                    }

                    InfoBanner(message: "Photo results are estimates. You'll review every item, correct portions and see a calorie range before saving. Photos are resized and stripped of location data before upload.",
                               systemImage: "sparkles", tint: .fuel)

                    if let error {
                        InfoBanner(title: "Couldn't analyse", message: error, systemImage: "exclamationmark.triangle", tint: .train)
                    }
                }
            }
            .padding(Spacing.l)
        }
        .background(Color.surface)
        .navigationTitle("Photo log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Analyze") { Task { await analyze() } }
                    .disabled(imageData == nil || isAnalyzing)
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                Haptics.capture()
                preview = image
                imageData = image.jpegData(compressionQuality: 0.9)
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    imageData = data
                    preview = UIImage(data: data)
                }
            }
        }
        .navigationDestination(item: $draft) { d in
            ConfirmItemsView(draft: d, title: "Confirm items", onSaved: finish)
        }
    }

    @ViewBuilder private var photoArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).fill(Color.card)
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
                    .accessibilityLabel("Selected meal photo")
            } else {
                VStack(spacing: Spacing.s) {
                    Image(systemName: "camera.viewfinder").font(.system(size: 44, weight: .light)).foregroundStyle(Color.fuel)
                    Text("Take or choose a photo of your meal").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if isAnalyzing {
                RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous).fill(.ultraThinMaterial)
                VStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Identifying foods and estimating portions…").font(.subheadline)
                }
            }
        }
        .frame(height: 280)
        .clipped()
    }

    private func analyze() async {
        guard let imageData else { return }
        isAnalyzing = true
        error = nil
        defer { isAnalyzing = false }
        let mealId = UUID().uuidString.lowercased()
        do {
            let jpeg = try ImagePreprocessor.prepareJPEG(from: imageData)
            var readings: [ScaleReadingInput] = []
            if includeScale, env.foodScale.state.isConnected, let g = env.foodScale.stableGrams {
                readings = [ScaleReadingInput(grams: g, label: nil)]
            }
            let result = try await env.recognition.analyzePhoto(jpegData: jpeg, mealId: mealId, scaleReadings: readings,
                                                                hint: hint, category: context.category)
            guard !result.analysis.items.isEmpty else {
                error = "No food was recognised. Try another angle, or log by search or barcode."
                return
            }
            var d = MealDraft(analysis: result.analysis, mealId: mealId, date: context.date, category: context.category, photoKey: result.photoKey)
            d.notes = hint
            Haptics.success()
            draft = d
        } catch {
            self.error = error.localizedDescription
            Haptics.warning()
        }
    }
}

/// UIKit camera wrapper (SwiftUI has no first-party camera capture view).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
