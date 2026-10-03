#if canImport(SwiftData)
import Foundation
import SwiftData
import CoreModels

/// On-device encrypted store (SwiftData) + outbox. The store directory and files use
/// `FileProtectionType.complete` (NSFileProtectionComplete): unreadable while the device is locked.
public actor LocalStore: ModelActor, OutboxStore {
    public nonisolated let modelContainer: ModelContainer
    public nonisolated let modelExecutor: any ModelExecutor

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        self.modelExecutor = DefaultSerialModelExecutor(modelContext: context)
    }

    public static let schema = Schema([
        MealEntity.self, FoodItemEntity.self, DailyMetricsEntity.self, BodyMeasurementEntity.self,
        WorkoutEntity.self, NoteEntity.self, PendingChange.self, SyncStateEntity.self,
    ])

    /// Creates the on-disk container in Application Support with complete file protection.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
        let fm = FileManager.default
        let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("HealthAppStore", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
        let url = dir.appendingPathComponent("healthapp.store")
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        applyFileProtection(in: dir)
        return container
    }

    /// Applies NSFileProtectionComplete to the store and its -wal/-shm siblings.
    static func applyFileProtection(in dir: URL) {
        let fm = FileManager.default
        try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.path)
        let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files {
            try? fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: dir.appendingPathComponent(f).path)
        }
    }

    // MARK: Meals (offline-first)

    /// Saves locally and appends an outbox entry.
    public func saveMeal(_ meal: Meal) throws {
        try upsertMealEntity(meal)
        try enqueue(SyncChange(entityType: .meal, id: meal.id, op: .upsert, baseVersion: meal.version, data: try JSONValue.encode(meal)))
        try modelContext.save()
    }

    public func deleteMeal(_ meal: Meal) throws {
        var tomb = meal
        tomb.deleted = true
        tomb.updatedAt = Date()
        try upsertMealEntity(tomb)
        try enqueue(SyncChange(entityType: .meal, id: meal.id, op: .delete, baseVersion: meal.version, data: try JSONValue.encode(tomb)))
        try modelContext.save()
    }

    public func meals(from: LocalDate, to: LocalDate) throws -> [Meal] {
        let lo = from.dayNumber, hi = to.dayNumber
        let descriptor = FetchDescriptor<MealEntity>(
            predicate: #Predicate { $0.dayNumber >= lo && $0.dayNumber <= hi && $0.isTombstone == false },
            sortBy: [SortDescriptor(\.loggedAt)])
        return try modelContext.fetch(descriptor).compactMap { try? $0.decoded() }
    }

    /// Replaces cached meals for a date range with server data, except meals that still have pending local changes.
    public func cacheServerMeals(_ meals: [Meal]) throws {
        let pendingIDs = try pendingEntityIDs()
        for meal in meals where !pendingIDs.contains(meal.id) { try upsertMealEntity(meal) }
        try modelContext.save()
    }

    private func upsertMealEntity(_ meal: Meal) throws {
        let id = meal.id
        let existing = try modelContext.fetch(FetchDescriptor<MealEntity>(predicate: #Predicate { $0.id == id })).first
        let entity: MealEntity
        if let existing {
            try existing.update(from: meal)
            for item in existing.items { modelContext.delete(item) }
            existing.items = []
            entity = existing
        } else {
            entity = try MealEntity(meal: meal)
            modelContext.insert(entity)
        }
        entity.items = meal.items.map { FoodItemEntity(item: $0, loggedAt: meal.loggedAt) }
    }

    /// Distinct recently-logged food names (Food → History).
    public func recentFoodNames(limit: Int = 50) throws -> [String] {
        var d = FetchDescriptor<FoodItemEntity>(sortBy: [SortDescriptor(\.loggedAt, order: .reverse)])
        d.fetchLimit = 500
        var seen = Set<String>(), out: [String] = []
        for item in try modelContext.fetch(d) where !seen.contains(item.name.lowercased()) {
            seen.insert(item.name.lowercased()); out.append(item.name)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Notes

    public func saveNote(_ note: Note, enqueue shouldEnqueue: Bool = true) throws {
        let day = note.date.dayNumber
        if let existing = try modelContext.fetch(FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.dayNumber == day })).first {
            existing.text = note.text; existing.tagsJoined = note.tags.joined(separator: ","); existing.updatedAt = Date()
        } else {
            modelContext.insert(NoteEntity(note: note))
        }
        if shouldEnqueue {
            try enqueue(SyncChange(entityType: .note, id: note.date.iso, op: .upsert, baseVersion: 0, data: try JSONValue.encode(note)))
        }
        try modelContext.save()
    }

    public func note(for date: LocalDate) throws -> Note? {
        let day = date.dayNumber
        return try modelContext.fetch(FetchDescriptor<NoteEntity>(predicate: #Predicate { $0.dayNumber == day })).first?.note
    }

    // MARK: Health caches (read-only offline fallback)

    public func cache(metrics: [DailyMetrics]) throws {
        for m in metrics {
            let key = "\(m.date.iso):\(m.source.rawValue)"
            if let existing = try modelContext.fetch(FetchDescriptor<DailyMetricsEntity>(predicate: #Predicate { $0.key == key })).first {
                existing.payload = try JSONCoding.makeEncoder().encode(m)
            } else {
                modelContext.insert(try DailyMetricsEntity(metrics: m))
            }
        }
        try modelContext.save()
    }

    public func cachedMetrics(from: LocalDate, to: LocalDate) throws -> [DailyMetrics] {
        let lo = from.dayNumber, hi = to.dayNumber
        let d = FetchDescriptor<DailyMetricsEntity>(predicate: #Predicate { $0.dayNumber >= lo && $0.dayNumber <= hi })
        return try modelContext.fetch(d).compactMap { try? JSONCoding.makeDecoder().decode(DailyMetrics.self, from: $0.payload) }
    }

    public func cache(body: [BodyMeasurement]) throws {
        for b in body {
            let id = b.id
            if try modelContext.fetch(FetchDescriptor<BodyMeasurementEntity>(predicate: #Predicate { $0.id == id })).isEmpty {
                modelContext.insert(try BodyMeasurementEntity(measurement: b))
            }
        }
        try modelContext.save()
    }

    public func cachedBody(from: Date, to: Date) throws -> [BodyMeasurement] {
        let d = FetchDescriptor<BodyMeasurementEntity>(predicate: #Predicate { $0.measuredAt >= from && $0.measuredAt < to },
                                                       sortBy: [SortDescriptor(\.measuredAt)])
        return try modelContext.fetch(d).compactMap { try? JSONCoding.makeDecoder().decode(BodyMeasurement.self, from: $0.payload) }
    }

    public func cache(workouts: [Workout]) throws {
        for w in workouts {
            let id = w.id
            if try modelContext.fetch(FetchDescriptor<WorkoutEntity>(predicate: #Predicate { $0.id == id })).isEmpty {
                modelContext.insert(try WorkoutEntity(workout: w))
            }
        }
        try modelContext.save()
    }

    public func cachedWorkouts(from: Date, to: Date) throws -> [Workout] {
        let d = FetchDescriptor<WorkoutEntity>(predicate: #Predicate { $0.start >= from && $0.start < to }, sortBy: [SortDescriptor(\.start)])
        return try modelContext.fetch(d).compactMap { try? JSONCoding.makeDecoder().decode(Workout.self, from: $0.payload) }
    }

    /// Wipes everything (sign-out / account deletion).
    public func eraseAll() throws {
        try modelContext.delete(model: MealEntity.self)
        try modelContext.delete(model: FoodItemEntity.self)
        try modelContext.delete(model: DailyMetricsEntity.self)
        try modelContext.delete(model: BodyMeasurementEntity.self)
        try modelContext.delete(model: WorkoutEntity.self)
        try modelContext.delete(model: NoteEntity.self)
        try modelContext.delete(model: PendingChange.self)
        try modelContext.delete(model: SyncStateEntity.self)
        try modelContext.save()
    }

    // MARK: Outbox

    private func enqueue(_ change: SyncChange) throws {
        modelContext.insert(try PendingChange(entry: OutboxEntry(change: change)))
    }

    private func pendingEntityIDs() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<PendingChange>()).map(\.entityID))
    }

    public func pendingEntries(limit: Int) async throws -> [OutboxEntry] {
        var d = FetchDescriptor<PendingChange>(sortBy: [SortDescriptor(\.createdAt)])
        d.fetchLimit = limit
        return try modelContext.fetch(d).compactMap { try? $0.entry() }
    }

    public func pendingCount() async -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<PendingChange>())) ?? 0
    }

    public func markApplied(_ entryIDs: [UUID], versions: [String: Int]) async throws {
        let ids = Set(entryIDs)
        for row in try modelContext.fetch(FetchDescriptor<PendingChange>()) where ids.contains(row.id) {
            if row.entityTypeRaw == EntityType.meal.rawValue, let v = versions[row.entityID] {
                let mealID = row.entityID
                if let meal = try modelContext.fetch(FetchDescriptor<MealEntity>(predicate: #Predicate { $0.id == mealID })).first,
                   var value = try? meal.decoded() {
                    value.version = v
                    try meal.update(from: value)
                }
                // Later queued edits of the same meal must now be based on the new server version.
                for other in try modelContext.fetch(FetchDescriptor<PendingChange>()) where other.entityID == mealID && !ids.contains(other.id) {
                    other.baseVersion = v
                }
            }
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    public func requeue(_ entryID: UUID, with change: SyncChange) async throws {
        guard let row = try modelContext.fetch(FetchDescriptor<PendingChange>(predicate: #Predicate { $0.id == entryID })).first else { return }
        row.baseVersion = change.baseVersion
        row.opRaw = change.op.rawValue
        row.payload = try change.data.map { try JSONCoding.makeEncoder().encode($0) }
        row.attempts += 1
        if change.entityType == .meal, let data = change.data, let meal = try? data.decode(as: Meal.self) {
            try upsertMealEntity(meal) // show the merged result immediately
        }
        try modelContext.save()
    }

    public func discard(_ entryIDs: [UUID]) async throws {
        let ids = Set(entryIDs)
        for row in try modelContext.fetch(FetchDescriptor<PendingChange>()) where ids.contains(row.id) { modelContext.delete(row) }
        try modelContext.save()
    }

    public func applyRemote(_ changes: [PulledChange]) async throws {
        let pending = try pendingEntityIDs()
        for change in changes where !pending.contains(change.id) {
            switch change.entityType {
            case .meal:
                if change.deleted {
                    let id = change.id
                    for m in try modelContext.fetch(FetchDescriptor<MealEntity>(predicate: #Predicate { $0.id == id })) { m.isTombstone = true }
                } else if let meal = try? change.data?.decode(as: Meal.self) {
                    var m = meal
                    m.version = change.version
                    try upsertMealEntity(m)
                }
            case .note:
                if let note = try? change.data?.decode(as: Note.self) { try saveNote(note, enqueue: false) }
            case .body:
                if let b = try? change.data?.decode(as: BodyMeasurement.self) { try cache(body: [b]) }
            case .workout:
                if let w = try? change.data?.decode(as: Workout.self) { try cache(workouts: [w]) }
            case .dailyMetrics:
                if let d = try? change.data?.decode(as: DailyMetrics.self) { try cache(metrics: [d]) }
            default:
                break // profile/goals/connections are re-fetched via GET /v1/me
            }
        }
        try modelContext.save()
    }

    public func syncCursor() async -> String? {
        let key = "pullCursor"
        return (try? modelContext.fetch(FetchDescriptor<SyncStateEntity>(predicate: #Predicate { $0.key == key })).first)?.value
    }

    public func setSyncCursor(_ cursor: String?) async {
        let key = "pullCursor"
        if let row = try? modelContext.fetch(FetchDescriptor<SyncStateEntity>(predicate: #Predicate { $0.key == key })).first {
            row.value = cursor
        } else {
            modelContext.insert(SyncStateEntity(key: key, value: cursor))
        }
        try? modelContext.save()
    }
}
#endif
