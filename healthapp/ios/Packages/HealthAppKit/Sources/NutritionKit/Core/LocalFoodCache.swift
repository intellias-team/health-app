import Foundation
import CoreModels

/// Small in-memory LRU cache for food details and recent search results, so repeated lookups
/// (and the food-scale flow, which re-uses the last picked foods) work offline.
public actor LocalFoodCache {
    private var details: [String: FoodDetail] = [:]
    private var searches: [String: [FoodSummary]] = [:]
    private var order: [String] = []
    private let capacity: Int
    public private(set) var recent: [FoodDetail] = []

    public init(capacity: Int = 200) { self.capacity = capacity }

    public func detail(for ref: FoodRef) -> FoodDetail? { details[key(ref)] }

    public func store(_ detail: FoodDetail) {
        let k = key(detail.foodRef)
        details[k] = detail
        touch(k)
    }

    public func searchResults(for query: String) -> [FoodSummary]? { searches[normalise(query)] }

    public func store(results: [FoodSummary], for query: String) {
        searches[normalise(query)] = results
        if searches.count > capacity { searches.removeAll() }
    }

    /// Marks a food as recently used (shown first in pickers).
    public func markUsed(_ detail: FoodDetail) {
        store(detail)
        recent.removeAll { $0.foodRef == detail.foodRef }
        recent.insert(detail, at: 0)
        if recent.count > 20 { recent.removeLast() }
    }

    /// Searches cached details by name (offline fallback).
    public func offlineSearch(_ query: String) -> [FoodSummary] {
        let q = normalise(query)
        return details.values.filter { $0.name.lowercased().contains(q) }.prefix(25).map {
            FoodSummary(foodRef: $0.foodRef, name: $0.name, brand: $0.brand, nutrientsPer100g: $0.nutrientsPer100g)
        }
    }

    private func touch(_ k: String) {
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > capacity { details.removeValue(forKey: order.removeFirst()) }
    }

    private func key(_ ref: FoodRef) -> String { "\(ref.db.rawValue):\(ref.id)" }
    private func normalise(_ q: String) -> String { q.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
