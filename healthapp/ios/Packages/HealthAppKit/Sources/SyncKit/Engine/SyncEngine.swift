import Foundation
import CoreModels
import Networking

/// Drains the outbox and pulls remote changes (docs/03 §3.4).
///
/// Triggered by `ConnectivityMonitor` (network regained), app foreground and the BGAppRefreshTask.
/// HealthKit-derived data is *not* sent through the outbox (it's re-derivable and upserted in batches).
public actor SyncEngine: SyncService {
    private let api: APIClient
    private let store: OutboxStore
    private let maxAttempts: Int
    private var running: Task<SyncReport, Error>?

    public init(api: APIClient, store: OutboxStore, maxAttempts: Int = 5) {
        self.api = api; self.store = store; self.maxAttempts = maxAttempts
    }

    public func pendingChangeCount() async -> Int { await store.pendingCount() }

    /// Coalesces concurrent calls into one run.
    public func syncNow() async throws -> SyncReport {
        if let running { return try await running.value }
        let task = Task { try await self.performSync() }
        running = task
        defer { running = nil }
        return try await task.value
    }

    private func performSync() async throws -> SyncReport {
        var report = SyncReport()

        // 1. Push (batches of ≤ 100).
        var rounds = 0
        while rounds < 10 {
            rounds += 1
            let pending = try await store.pendingEntries(limit: 500)
            if pending.isEmpty { break }
            let (toPush, redundant) = OutboxCoalescer.coalesce(pending)
            if !redundant.isEmpty { try await store.discard(redundant) }
            let batch = Array(toPush.prefix(100))
            let response = try await api.send(try API.syncPush(batch.map(\.change)))
            let byID = Dictionary(batch.map { ($0.change.id, $0) }, uniquingKeysWith: { a, _ in a })

            var applied: [UUID] = []
            var versions: [String: Int] = [:]
            var requeued = 0
            for result in response.results {
                guard let entry = byID[result.id] else { continue }
                switch result.status {
                case .applied:
                    applied.append(entry.id)
                    versions[result.id] = result.serverVersion
                    report.pushed += 1
                case .conflict:
                    report.conflictsResolved += 1
                    if entry.attempts + 1 >= maxAttempts {
                        try await store.discard([entry.id])
                        continue
                    }
                    switch ConflictResolver.resolve(change: entry.change, serverVersion: result.serverVersion, serverItem: result.serverItem) {
                    case .requeue(let change):
                        try await store.requeue(entry.id, with: change)
                        requeued += 1
                    case .acceptServer(let pulled):
                        try await store.applyRemote([pulled])
                        try await store.discard([entry.id])
                    }
                }
            }
            if !applied.isEmpty { try await store.markApplied(applied, versions: versions) }
            // Stop when nothing progressed this round, to avoid hot loops.
            if applied.isEmpty && requeued == 0 { break }
        }

        // 2. Pull.
        var cursor = await store.syncCursor()
        var pages = 0
        repeat {
            pages += 1
            let page = try await api.send(API.syncPull(since: cursor))
            if !page.changes.isEmpty { try await store.applyRemote(page.changes) }
            report.pulled += page.changes.count
            cursor = page.cursor ?? cursor
            await store.setSyncCursor(cursor)
            if !page.hasMore { break }
        } while pages < 50

        report.remainingPending = await store.pendingCount()
        report.finishedAt = Date()
        return report
    }
}
