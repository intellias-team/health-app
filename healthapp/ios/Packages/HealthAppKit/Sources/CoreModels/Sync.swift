import Foundation

/// `entityType` values (docs/02 §2.2).
public enum EntityType: String, Codable, Hashable, Sendable, CaseIterable {
    case profile, goals, connection, meal, dailyMetrics, body, workout, customFood, recipe, note, cycle, device, analysis, chat
}

public enum SyncOp: String, Codable, Hashable, Sendable { case upsert, delete }

/// One outbox entry pushed to `POST /v1/sync/push`.
public struct SyncChange: Codable, Hashable, Sendable {
    public var entityType: EntityType
    public var id: String
    public var op: SyncOp
    public var baseVersion: Int
    public var data: JSONValue?
    public init(entityType: EntityType, id: String, op: SyncOp, baseVersion: Int, data: JSONValue?) {
        self.entityType = entityType; self.id = id; self.op = op; self.baseVersion = baseVersion; self.data = data
    }
}

public struct SyncPushRequest: Codable, Hashable, Sendable {
    public var changes: [SyncChange]
    public init(changes: [SyncChange]) { self.changes = changes }
}

public enum SyncResultStatus: String, Codable, Hashable, Sendable { case applied, conflict }

public struct SyncPushResult: Codable, Hashable, Sendable {
    public var id: String
    public var status: SyncResultStatus
    public var serverVersion: Int
    public var serverItem: JSONValue?
    public init(id: String, status: SyncResultStatus, serverVersion: Int, serverItem: JSONValue? = nil) {
        self.id = id; self.status = status; self.serverVersion = serverVersion; self.serverItem = serverItem
    }
}

public struct SyncPushResponse: Codable, Hashable, Sendable {
    public var results: [SyncPushResult]
    public init(results: [SyncPushResult]) { self.results = results }
}

public struct PulledChange: Codable, Hashable, Sendable {
    public var entityType: EntityType
    public var id: String
    public var deleted: Bool
    public var version: Int
    public var data: JSONValue?
    public init(entityType: EntityType, id: String, deleted: Bool, version: Int, data: JSONValue?) {
        self.entityType = entityType; self.id = id; self.deleted = deleted; self.version = version; self.data = data
    }
}

/// `GET /v1/sync/pull` response.
public struct SyncPullResponse: Codable, Hashable, Sendable {
    public var changes: [PulledChange]
    public var cursor: String?
    public var hasMore: Bool
    public init(changes: [PulledChange], cursor: String?, hasMore: Bool) { self.changes = changes; self.cursor = cursor; self.hasMore = hasMore }
}

public struct SyncReport: Hashable, Sendable {
    public var pushed: Int
    public var conflictsResolved: Int
    public var pulled: Int
    public var remainingPending: Int
    public var finishedAt: Date
    public init(pushed: Int = 0, conflictsResolved: Int = 0, pulled: Int = 0, remainingPending: Int = 0, finishedAt: Date = Date()) {
        self.pushed = pushed; self.conflictsResolved = conflictsResolved; self.pulled = pulled
        self.remainingPending = remainingPending; self.finishedAt = finishedAt
    }
}
