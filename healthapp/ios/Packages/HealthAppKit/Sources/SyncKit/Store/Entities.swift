#if canImport(SwiftData)
import Foundation
import SwiftData
import CoreModels

// SwiftData mirror of the user-owned entities (docs/02 §2.5). Each entity keeps indexed key fields for
// querying plus the full JSON `payload` of the CoreModels value, so the API model can evolve additively
// without SwiftData migrations.

@Model
public final class MealEntity {
    @Attribute(.unique) public var id: String
    /// `LocalDate.dayNumber` for cheap range predicates.
    public var dayNumber: Int
    public var loggedAt: Date
    public var updatedAt: Date
    public var version: Int
    public var isTombstone: Bool
    public var payload: Data
    @Relationship(deleteRule: .cascade, inverse: \FoodItemEntity.meal)
    public var items: [FoodItemEntity] = []

    public init(meal: Meal) throws {
        id = meal.id
        dayNumber = meal.date.dayNumber
        loggedAt = meal.loggedAt
        updatedAt = meal.updatedAt ?? Date()
        version = meal.version
        isTombstone = meal.deleted
        payload = try JSONCoding.makeEncoder().encode(meal)
    }

    public func update(from meal: Meal) throws {
        dayNumber = meal.date.dayNumber
        loggedAt = meal.loggedAt
        updatedAt = meal.updatedAt ?? Date()
        version = meal.version
        isTombstone = meal.deleted
        payload = try JSONCoding.makeEncoder().encode(meal)
    }

    public func decoded() throws -> Meal { try JSONCoding.makeDecoder().decode(Meal.self, from: payload) }
}

/// Denormalised item rows (food history / "recent foods" queries without decoding every meal).
@Model
public final class FoodItemEntity {
    public var itemID: String
    public var name: String
    public var grams: Double
    public var kcal: Double
    public var weightSourceRaw: String
    public var loggedAt: Date
    public var meal: MealEntity?

    public init(item: FoodItem, loggedAt: Date) {
        itemID = item.id; name = item.name; grams = item.grams; kcal = item.nutrients.kcal
        weightSourceRaw = item.weightSource.rawValue; self.loggedAt = loggedAt
    }
}

@Model
public final class DailyMetricsEntity {
    /// "<yyyy-mm-dd>:<source>" (same id the backend uses for daily-metrics sync)
    @Attribute(.unique) public var key: String
    public var dayNumber: Int
    public var source: String
    public var payload: Data

    public init(metrics: DailyMetrics) throws {
        key = "\(metrics.date.iso):\(metrics.source.rawValue)"
        dayNumber = metrics.date.dayNumber
        source = metrics.source.rawValue
        payload = try JSONCoding.makeEncoder().encode(metrics)
    }
}

@Model
public final class BodyMeasurementEntity {
    @Attribute(.unique) public var id: String
    public var measuredAt: Date
    public var payload: Data

    public init(measurement: BodyMeasurement) throws {
        id = measurement.id; measuredAt = measurement.measuredAt
        payload = try JSONCoding.makeEncoder().encode(measurement)
    }
}

@Model
public final class WorkoutEntity {
    @Attribute(.unique) public var id: String
    public var start: Date
    public var payload: Data

    public init(workout: Workout) throws {
        id = workout.id; start = workout.start
        payload = try JSONCoding.makeEncoder().encode(workout)
    }
}

@Model
public final class NoteEntity {
    @Attribute(.unique) public var dayNumber: Int
    public var text: String
    public var tagsJoined: String
    public var updatedAt: Date

    public init(note: Note) {
        dayNumber = note.date.dayNumber; text = note.text; tagsJoined = note.tags.joined(separator: ","); updatedAt = Date()
    }

    public var note: Note {
        Note(date: LocalDate(dayNumber: dayNumber), text: text, tags: tagsJoined.split(separator: ",").map(String.init))
    }
}

/// Outbox row (docs/03 §3.4 step 1).
@Model
public final class PendingChange {
    @Attribute(.unique) public var id: UUID
    public var createdAt: Date
    public var entityTypeRaw: String
    public var entityID: String
    public var opRaw: String
    public var baseVersion: Int
    public var payload: Data?
    public var attempts: Int

    public init(entry: OutboxEntry) throws {
        id = entry.id; createdAt = entry.createdAt
        entityTypeRaw = entry.change.entityType.rawValue; entityID = entry.change.id
        opRaw = entry.change.op.rawValue; baseVersion = entry.change.baseVersion
        payload = try entry.change.data.map { try JSONCoding.makeEncoder().encode($0) }
        attempts = entry.attempts
    }

    public func entry() throws -> OutboxEntry {
        let data = try payload.map { try JSONCoding.makeDecoder().decode(JSONValue.self, from: $0) }
        let change = SyncChange(entityType: EntityType(rawValue: entityTypeRaw) ?? .meal, id: entityID,
                                op: SyncOp(rawValue: opRaw) ?? .upsert, baseVersion: baseVersion, data: data)
        return OutboxEntry(id: id, createdAt: createdAt, change: change, attempts: attempts)
    }
}

@Model
public final class SyncStateEntity {
    @Attribute(.unique) public var key: String
    public var value: String?
    public init(key: String, value: String?) { self.key = key; self.value = value }
}
#endif
