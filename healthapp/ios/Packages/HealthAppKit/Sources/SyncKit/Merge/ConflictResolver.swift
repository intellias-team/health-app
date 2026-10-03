import Foundation
import CoreModels

/// Conflict resolution for offline sync (docs/03 §3.4 step 3):
/// * **meals** — field-level last-writer-wins; items merged by item `id`, newest `updatedAt` wins;
/// * **everything else** — server wins.
///
/// Foundation-only so it is unit-tested on Linux.
public enum ConflictResolver {
    public enum Resolution: Equatable, Sendable {
        /// Re-queue this change (with `baseVersion` = server version) — the merged entity must be pushed again.
        case requeue(SyncChange)
        /// Accept the server item locally and drop the pending change.
        case acceptServer(PulledChange)
    }

    /// Merges a local meal with the server's conflicting copy.
    /// - Parameter base: the last version both sides agreed on, if known. With a base, deletions of items on
    ///   either side are honoured; without one, items are unioned (nothing the user logged is silently lost).
    public static func mergeMeal(local: Meal, server: Meal, base: Meal? = nil) -> Meal {
        let localTime = local.updatedAt ?? .distantPast
        let serverTime = server.updatedAt ?? .distantPast
        let localIsNewer = localTime > serverTime

        // Tombstones: a deletion wins if it is the newer write.
        if server.deleted && !localIsNewer { return server }
        if local.deleted && localIsNewer {
            var tomb = local
            tomb.version = server.version
            return tomb
        }

        let newer = localIsNewer ? local : server
        var merged = newer
        merged.deleted = false
        merged.version = server.version
        merged.updatedAt = max(localTime, serverTime)

        // Field-level: scalar fields come from the newer writer; photoKey is kept if either side has one.
        merged.photoKey = newer.photoKey ?? (localIsNewer ? server.photoKey : local.photoKey)

        // Items by id.
        let baseIDs = Set(base?.items.map(\.id) ?? [])
        let localByID = Dictionary(local.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let serverByID = Dictionary(server.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var orderedIDs: [String] = newer.items.map(\.id)
        let other = localIsNewer ? server.items : local.items
        for item in other where !orderedIDs.contains(item.id) { orderedIDs.append(item.id) }

        var items: [FoodItem] = []
        for id in orderedIDs {
            switch (localByID[id], serverByID[id]) {
            case let (l?, s?):
                items.append(localIsNewer ? l : s)
            case let (l?, nil):
                // Present locally only: added locally (keep) or deleted on server (keep only if local is newer).
                if !baseIDs.contains(id) || localIsNewer { items.append(l) }
            case let (nil, s?):
                // Present on server only: added remotely (keep) or deleted locally (keep only if server is newer).
                if !baseIDs.contains(id) || !localIsNewer { items.append(s) }
            case (nil, nil):
                break
            }
        }
        merged.items = items
        merged.recomputeTotals()
        return merged
    }

    /// Resolves one `conflict` result from `/v1/sync/push`.
    public static func resolve(change: SyncChange, serverVersion: Int, serverItem: JSONValue?) -> Resolution {
        guard let serverItem else {
            // Server has no item (e.g. purged) — re-push ours on top of the server version.
            var c = change
            c.baseVersion = serverVersion
            return .requeue(c)
        }
        let serverDeleted = serverItem["deleted"].flatMap { if case .bool(let b) = $0 { return b } else { return nil } } ?? false
        if change.entityType == .meal,
           let localData = change.data,
           let local = try? localData.decode(as: Meal.self),
           let server = try? serverItem.decode(as: Meal.self) {
            let merged = mergeMeal(local: local, server: server)
            if merged.deleted && server.deleted {
                return .acceptServer(PulledChange(entityType: .meal, id: change.id, deleted: true, version: serverVersion, data: serverItem))
            }
            let op: SyncOp = merged.deleted ? .delete : .upsert
            let data = (try? JSONValue.encode(merged)) ?? localData
            return .requeue(SyncChange(entityType: .meal, id: change.id, op: op, baseVersion: serverVersion, data: data))
        }
        return .acceptServer(PulledChange(entityType: change.entityType, id: change.id, deleted: serverDeleted, version: serverVersion, data: serverItem))
    }
}
