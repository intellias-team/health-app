import Foundation
import CoreModels
import Networking

/// Client side of the AI meal-photo pipeline (docs/03 §3.3 "AI"):
/// 1. `POST /v1/photos/upload-url` → presigned S3 PUT (5 min, image/jpeg)
/// 2. PUT the downscaled, metadata-stripped JPEG (≤ 8 MB)
/// 3. `POST /v1/ai/meal-analysis` with optional food-scale readings → `MealAnalysis`
///
/// The model only identifies foods and estimates grams with a range; nutrients come from the nutrition
/// database server-side. The UI must always label photo results "Estimate" (see `DraftItem.badge`) unless
/// an item was matched to a scale reading.
public struct MealPhotoPipeline: MealRecognitionService {
    public static let maxUploadBytes = 8 * 1024 * 1024
    private let api: APIClient

    public init(api: APIClient) { self.api = api }

    public func analyzePhoto(jpegData: Data, mealId: String, scaleReadings: [ScaleReadingInput], hint: String?,
                             category: MealCategory?) async throws -> (analysis: MealAnalysis, photoKey: String?) {
        guard jpegData.count <= Self.maxUploadBytes else {
            throw APIError.http(status: 413, code: "PAYLOAD_TOO_LARGE", message: "Photo is too large.")
        }
        let upload = try await api.send(try API.photoUploadURL(mealId: mealId, contentLength: jpegData.count))
        if let maxBytes = upload.maxBytes, jpegData.count > maxBytes {
            throw APIError.http(status: 413, code: "PAYLOAD_TOO_LARGE", message: "Photo is too large.")
        }
        // The presigned signature covers these headers (content-type + retention tag); all must be sent.
        try await api.uploadPresigned(to: upload.uploadUrl, data: jpegData, contentType: "image/jpeg",
                                      requiredHeaders: upload.requiredHeaders ?? [:])
        var analysis = try await api.send(try API.mealAnalysis(MealAnalysisBody(
            photoKey: upload.photoKey,
            scaleReadings: scaleReadings.isEmpty ? nil : scaleReadings,
            hint: hint?.isEmpty == true ? nil : hint,
            mealCategory: category)))
        analysis = Self.enforceEstimateSemantics(analysis)
        return (analysis, upload.photoKey)
    }

    public func parseVoice(transcript: String, category: MealCategory?) async throws -> [AnalyzedItem] {
        let items = try await api.send(try API.voiceParse(VoiceParseBody(transcript: transcript, mealCategory: category))).items
        // Spoken amounts are estimates unless the user later weighs them.
        return items.map { var i = $0; if i.weightSource == .scale { i.weightSource = .estimated }; return i }
    }

    /// Defensive: never present a photo estimate as exact. Only items the server matched to a scale reading may be
    /// exact; everything else keeps (or gets) a non-zero range.
    static func enforceEstimateSemantics(_ analysis: MealAnalysis) -> MealAnalysis {
        var a = analysis
        a.items = a.items.map { item in
            var i = item
            if i.weightSource != .scale {
                i.weightSource = .estimated
                if i.range.isExact && i.nutrients.kcal > 0 {
                    i.range = NutrientRange(kcalLow: i.nutrients.kcal * 0.75, kcalHigh: i.nutrients.kcal * 1.25)
                }
            }
            return i
        }
        a.isEstimate = a.items.contains { $0.weightSource != .scale }
        return a
    }
}
