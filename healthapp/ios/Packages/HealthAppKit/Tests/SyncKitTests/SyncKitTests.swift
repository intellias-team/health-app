import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SyncKit
import CoreModels
import Networking

final class ConflictResolverTests: XCTestCase {
    let date = LocalDate(year: 2026, month: 10, day: 3)
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func item(_ id: String, _ name: String, grams: Double, kcal: Double) -> FoodItem {
        FoodItem(id: id, name: name, grams: grams, weightSource: .scale, nutrients: Nutrients(kcal: kcal), range: .exact(kcal))
    }

    func meal(items: [FoodItem], notes: String? = nil, category: MealCategory = .lunch, updated: TimeInterval, version: Int) -> Meal {
        Meal(id: "m1", date: date, loggedAt: t0, category: category, source: .scale, items: items, notes: notes,
             updatedAt: t0.addingTimeInterval(updated), version: version)
    }

    func testNewerLocalWinsScalarFieldsAndSharedItems() {
        let server = meal(items: [item("a", "Rice", grams: 100, kcal: 130), item("b", "Chicken", grams: 100, kcal: 165)],
                          notes: "server", category: .lunch, updated: 10, version: 4)
        let local = meal(items: [item("a", "Rice", grams: 150, kcal: 195), item("b", "Chicken", grams: 100, kcal: 165)],
                         notes: "local", category: .dinner, updated: 20, version: 3)
        let merged = ConflictResolver.mergeMeal(local: local, server: server)
        XCTAssertEqual(merged.notes, "local")
        XCTAssertEqual(merged.category, .dinner)
        XCTAssertEqual(merged.items.first { $0.id == "a" }?.grams, 150)
        XCTAssertEqual(merged.version, 4, "takes server version so the re-push passes the conditional write")
        XCTAssertEqual(merged.totals.kcal, 360)
    }

    func testNewerServerWinsSharedItems() {
        let server = meal(items: [item("a", "Rice", grams: 120, kcal: 156)], notes: "server", updated: 30, version: 5)
        let local = meal(items: [item("a", "Rice", grams: 150, kcal: 195)], notes: "local", updated: 20, version: 4)
        let merged = ConflictResolver.mergeMeal(local: local, server: server)
        XCTAssertEqual(merged.items.map(\.grams), [120])
        XCTAssertEqual(merged.notes, "server")
    }

    func testItemsAddedOnBothSidesAreUnioned() {
        let base = meal(items: [item("a", "Rice", grams: 100, kcal: 130)], updated: 0, version: 3)
        let server = meal(items: base.items + [item("s", "Salad", grams: 80, kcal: 20)], updated: 10, version: 4)
        let local = meal(items: base.items + [item("l", "Yogurt", grams: 150, kcal: 90)], updated: 20, version: 3)
        for b in [nil, base] as [Meal?] {
            let merged = ConflictResolver.mergeMeal(local: local, server: server, base: b)
            XCTAssertEqual(Set(merged.items.map(\.id)), ["a", "s", "l"])
            XCTAssertEqual(merged.totals.kcal, 240)
        }
    }

    func testDeletionHonouredWithBase() {
        let base = meal(items: [item("a", "Rice", grams: 100, kcal: 130), item("b", "Chicken", grams: 100, kcal: 165)], updated: 0, version: 3)
        // Local (newer) removed "b"; server edited only notes.
        let local = meal(items: [base.items[0]], updated: 20, version: 3)
        let server = meal(items: base.items, notes: "server", updated: 10, version: 4)
        let merged = ConflictResolver.mergeMeal(local: local, server: server, base: base)
        XCTAssertEqual(merged.items.map(\.id), ["a"])
    }

    func testServerTombstoneWinsWhenNewer() {
        var server = meal(items: [], updated: 30, version: 6)
        server.deleted = true
        let local = meal(items: [item("a", "Rice", grams: 100, kcal: 130)], updated: 20, version: 5)
        XCTAssertTrue(ConflictResolver.mergeMeal(local: local, server: server).deleted)
    }

    func testLocalDeleteWinsWhenNewer() {
        let server = meal(items: [item("a", "Rice", grams: 100, kcal: 130)], updated: 10, version: 6)
        var local = server
        local.deleted = true
        local.updatedAt = t0.addingTimeInterval(20)
        let merged = ConflictResolver.mergeMeal(local: local, server: server)
        XCTAssertTrue(merged.deleted)
        XCTAssertEqual(merged.version, 6)
    }

    func testResolveMealRequeuesMergedWithServerVersion() throws {
        let server = meal(items: [item("a", "Rice", grams: 100, kcal: 130)], updated: 10, version: 7)
        let local = meal(items: [item("a", "Rice", grams: 100, kcal: 130), item("l", "Yogurt", grams: 150, kcal: 90)], updated: 20, version: 6)
        let change = SyncChange(entityType: .meal, id: "m1", op: .upsert, baseVersion: 6, data: try JSONValue.encode(local))
        guard case .requeue(let requeued) = ConflictResolver.resolve(change: change, serverVersion: 7, serverItem: try JSONValue.encode(server)) else {
            return XCTFail("expected requeue")
        }
        XCTAssertEqual(requeued.baseVersion, 7)
        let merged = try XCTUnwrap(requeued.data).decode(as: Meal.self)
        XCTAssertEqual(merged.items.count, 2)
    }

    func testResolveNonMealServerWins() throws {
        let note = Note(date: date, text: "server text")
        let change = SyncChange(entityType: .note, id: date.iso, op: .upsert, baseVersion: 1, data: try JSONValue.encode(Note(date: date, text: "local")))
        guard case .acceptServer(let pulled) = ConflictResolver.resolve(change: change, serverVersion: 3, serverItem: try JSONValue.encode(note)) else {
            return XCTFail("expected server wins")
        }
        XCTAssertEqual(pulled.version, 3)
        XCTAssertEqual(try pulled.data?.decode(as: Note.self).text, "server text")
    }

    func testCoalescerKeepsFirstBaseVersionAndLatestData() {
        let c1 = OutboxEntry(createdAt: t0, change: SyncChange(entityType: .meal, id: "m1", op: .upsert, baseVersion: 2, data: .string("v1")))
        let c2 = OutboxEntry(createdAt: t0.addingTimeInterval(1), change: SyncChange(entityType: .meal, id: "m1", op: .upsert, baseVersion: 2, data: .string("v2")))
        let c3 = OutboxEntry(createdAt: t0.addingTimeInterval(2), change: SyncChange(entityType: .meal, id: "m1", op: .delete, baseVersion: 3, data: nil))
        let other = OutboxEntry(createdAt: t0.addingTimeInterval(1.5), change: SyncChange(entityType: .note, id: "n", op: .upsert, baseVersion: 0, data: nil))
        let (push, redundant) = OutboxCoalescer.coalesce([c3, c1, other, c2])
        XCTAssertEqual(push.count, 2)
        XCTAssertEqual(push[0].change.op, .delete)
        XCTAssertEqual(push[0].change.baseVersion, 2)
        XCTAssertEqual(Set(redundant), [c1.id, c2.id])
    }
}

// MARK: - Engine with fakes

actor InMemoryOutbox: OutboxStore {
    var entries: [OutboxEntry] = []
    var applied: [String: Int] = [:]
    var remote: [PulledChange] = []
    var cursor: String?

    init(_ entries: [OutboxEntry]) { self.entries = entries }

    func pendingEntries(limit: Int) async throws -> [OutboxEntry] { Array(entries.prefix(limit)) }
    func pendingCount() async -> Int { entries.count }
    func markApplied(_ entryIDs: [UUID], versions: [String: Int]) async throws {
        entries.removeAll { entryIDs.contains($0.id) }
        applied.merge(versions) { $1 }
    }
    func requeue(_ entryID: UUID, with change: SyncChange) async throws {
        if let i = entries.firstIndex(where: { $0.id == entryID }) { entries[i].change = change; entries[i].attempts += 1 }
    }
    func discard(_ entryIDs: [UUID]) async throws { entries.removeAll { entryIDs.contains($0.id) } }
    func applyRemote(_ changes: [PulledChange]) async throws { remote += changes }
    func syncCursor() async -> String? { cursor }
    func setSyncCursor(_ cursor: String?) async { self.cursor = cursor }
}

/// Fake server: first push of a meal conflicts, second applies.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pushes = 0
    var serverMeal: Meal
    init(serverMeal: Meal) { self.serverMeal = serverMeal }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let encoder = JSONCoding.makeEncoder()
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        if url.path.hasSuffix("/sync/push") {
            let body = try JSONCoding.makeDecoder().decode(SyncPushRequest.self, from: request.httpBody ?? Data())
            let n = lock.withLock { pushes += 1; return pushes }
            let results = try body.changes.map { c -> SyncPushResult in
                if n == 1 { return SyncPushResult(id: c.id, status: .conflict, serverVersion: serverMeal.version, serverItem: try JSONValue.encode(serverMeal)) }
                XCTAssertEqual(c.baseVersion, serverMeal.version)
                return SyncPushResult(id: c.id, status: .applied, serverVersion: serverMeal.version + 1)
            }
            return (try encoder.encode(SyncPushResponse(results: results)), ok)
        }
        if url.path.hasSuffix("/sync/pull") {
            let page = SyncPullResponse(changes: [PulledChange(entityType: .note, id: "2026-10-03", deleted: false, version: 1, data: .object(["text": .string("x")]))],
                                        cursor: "UPD#2026-10-03T13:00:00Z#note#2026-10-03", hasMore: false)
            return (try encoder.encode(page), ok)
        }
        return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
}

final class SyncEngineTests: XCTestCase {
    func testPushConflictMergeRepushThenPull() async throws {
        let date = LocalDate(year: 2026, month: 10, day: 3)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let a = FoodItem(id: "a", name: "Rice", grams: 100, weightSource: .scale, nutrients: Nutrients(kcal: 130))
        let b = FoodItem(id: "b", name: "Yogurt", grams: 150, weightSource: .scale, nutrients: Nutrients(kcal: 90))
        let server = Meal(id: "m1", date: date, loggedAt: t0, category: .lunch, source: .scale, items: [a], updatedAt: t0.addingTimeInterval(5), version: 4)
        let local = Meal(id: "m1", date: date, loggedAt: t0, category: .lunch, source: .scale, items: [a, b], updatedAt: t0.addingTimeInterval(9), version: 3)
        let store = InMemoryOutbox([OutboxEntry(change: SyncChange(entityType: .meal, id: "m1", op: .upsert, baseVersion: 3, data: try JSONValue.encode(local)))])
        let api = APIClient(baseURL: URL(string: "https://api.example.com/")!, transport: FakeTransport(serverMeal: server), baseDelay: 0) { _ in "t0k" }
        let engine = SyncEngine(api: api, store: store)

        let report = try await engine.syncNow()
        XCTAssertEqual(report.conflictsResolved, 1)
        XCTAssertEqual(report.pushed, 1)
        XCTAssertEqual(report.pulled, 1)
        XCTAssertEqual(report.remainingPending, 0)
        let applied = await store.applied
        XCTAssertEqual(applied["m1"], 5)
        let cursor = await store.cursor
        XCTAssertEqual(cursor, "UPD#2026-10-03T13:00:00Z#note#2026-10-03")
    }

    func testAPIClientErrorEnvelopeAndQuery() async throws {
        final class Echo: HTTPTransport, @unchecked Sendable {
            var lastURL: URL?
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lastURL = request.url
                let body = #"{"error":{"code":"VALIDATION_ERROR","message":"bad range"}}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!)
            }
        }
        let echo = Echo()
        let api = APIClient(baseURL: URL(string: "https://api.example.com/")!, transport: echo, baseDelay: 0) { _ in "tok" }
        do {
            _ = try await api.send(API.meals(from: LocalDate(year: 2026, month: 10, day: 1), to: LocalDate(year: 2026, month: 10, day: 3)))
            XCTFail("expected error")
        } catch let e as APIError {
            XCTAssertEqual(e, .http(status: 400, code: "VALIDATION_ERROR", message: "bad range"))
        }
        XCTAssertEqual(echo.lastURL?.absoluteString, "https://api.example.com/v1/meals?from=2026-10-01&to=2026-10-03")
        XCTAssertEqual(API.deleteMeal(id: "m1", date: LocalDate(year: 2026, month: 10, day: 3)).query, [QueryItem("date", "2026-10-03")])
        XCTAssertNotNil(APIError.http(status: 422, code: "AI_REFUSED", message: nil).errorDescription?.range(of: "couldn't analyse"))
        XCTAssertNotNil(APIError.http(status: 429, code: "RATE_LIMITED", message: nil).errorDescription?.range(of: "limit"))
        XCTAssertEqual(APIError.http(status: 400, code: "X", message: "raw").errorDescription, "raw")
        XCTAssertEqual(API.food(FoodRef(db: .usda, id: "171 477")).path, "/v1/foods/usda/171%20477")
        XCTAssertEqual(try API.updateConnection(provider: "bodyscale:abc", enabledMetrics: [], status: .connected).path, "/v1/connections/bodyscale:abc")
    }
}
