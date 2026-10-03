import Foundation
import CoreModels

/// A queued local change (value-type mirror of the SwiftData `PendingChange` row).
public struct OutboxEntry: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var change: SyncChange
    public var attempts: Int

    public init(id: UUID = UUID(), createdAt: Date = Date(), change: SyncChange, attempts: Int = 0) {
        self.id = id; self.createdAt = createdAt; self.change = change; self.attempts = attempts
    }
}

/// Persistence the sync engine needs. Implemented by the SwiftData `LocalStore` (and by in-memory fakes in tests).
public protocol OutboxStore: Sendable {
    func pendingEntries(limit: Int) async throws -> [OutboxEntry]
    func pendingCount() async -> Int
    /// Removes entries that the server applied and records the new server version on the local entity.
    func markApplied(_ entryIDs: [UUID], versions: [String: Int]) async throws
    /// Replaces an entry's change (after conflict resolution) and bumps its attempt counter.
    func requeue(_ entryID: UUID, with change: SyncChange) async throws
    /// Drops entries without applying (server won or retries exhausted).
    func discard(_ entryIDs: [UUID]) async throws
    /// Applies remote changes (pull, or server-wins conflict items) to local entities.
    func applyRemote(_ changes: [PulledChange]) async throws
    func syncCursor() async -> String?
    func setSyncCursor(_ cursor: String?) async
}

public enum OutboxCoalescer {
    /// Collapses several pending changes for the same entity into the latest one, keeping the *first*
    /// entry's `baseVersion` (the version the server last confirmed). A delete supersedes earlier upserts.
    /// Returns the entries to push and the ids of entries made redundant.
    public static func coalesce(_ entries: [OutboxEntry]) -> (push: [OutboxEntry], redundant: [UUID]) {
        var latest: [String: OutboxEntry] = [:]
        var firstBase: [String: Int] = [:]
        var order: [String] = []
        var redundant: [UUID] = []
        for e in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            let key = "\(e.change.entityType.rawValue)#\(e.change.id)"
            if let prev = latest[key] {
                redundant.append(prev.id)
            } else {
                order.append(key)
                firstBase[key] = e.change.baseVersion
            }
            latest[key] = e
        }
        let push = order.compactMap { key -> OutboxEntry? in
            guard var e = latest[key] else { return nil }
            e.change.baseVersion = firstBase[key] ?? e.change.baseVersion
            return e
        }
        return (push, redundant)
    }
}
