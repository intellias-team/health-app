import Foundation
import CoreModels
import Networking

/// `NutritionDatabase` backed by the backend's `/v1/foods*` routes (USDA FDC, Open Food Facts, custom foods),
/// with a local cache for offline search and re-use.
public struct RemoteNutritionDatabase: NutritionDatabase {
    private let api: APIClient
    private let cache: LocalFoodCache

    public init(api: APIClient, cache: LocalFoodCache = LocalFoodCache()) {
        self.api = api; self.cache = cache
    }

    public func search(query: String, limit: Int) async throws -> [FoodSummary] {
        do {
            let foods = try await api.send(API.searchFoods(query, limit: limit)).foods
            await cache.store(results: foods, for: query)
            return foods
        } catch {
            if let cached = await cache.searchResults(for: query) { return cached }
            let offline = await cache.offlineSearch(query)
            if !offline.isEmpty { return offline }
            throw error
        }
    }

    public func food(_ ref: FoodRef) async throws -> FoodDetail {
        if let cached = await cache.detail(for: ref) { return cached }
        let detail = try await api.send(API.food(ref)).food
        await cache.markUsed(detail)
        return detail
    }

    public func barcode(_ gtin: String) async throws -> FoodDetail? {
        do {
            let detail = try await api.send(API.barcode(gtin)).food
            await cache.markUsed(detail)
            return detail
        } catch let error as APIError where error.status == 404 {
            return nil
        }
    }

    public func saveCustomFood(_ food: CustomFood) async throws -> CustomFood {
        let saved = try await api.send(try API.putCustomFood(food)).food
        await cache.markUsed(saved.asDetail)
        return saved
    }
}
