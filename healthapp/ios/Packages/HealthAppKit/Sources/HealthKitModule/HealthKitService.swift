#if canImport(HealthKit)
import Foundation
import HealthKit
import CoreModels

/// Apple Health adapter (`HealthDataSource`).
///
/// Reads: steps, active/basal energy, heart rate, resting HR, HRV SDNN, sleep analysis, workouts, body mass,
/// body fat %, lean body mass, BMI, water, VO₂max, respiratory rate, sleeping wrist temperature.
/// Writes: body mass, body fat %, dietary energy/protein/carbs/fat/fiber/sugar/sodium, water.
public final class HealthKitService: HealthDataSource, @unchecked Sendable {
    private let store: HKHealthStore
    private let calendar: Calendar
    private var observerQueries: [HKObserverQuery] = []
    private let lock = NSLock()

    public init(store: HKHealthStore = HKHealthStore(), calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
    }

    public var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Type mapping

    static func quantityIdentifier(for t: HealthMetricType) -> HKQuantityTypeIdentifier? {
        switch t {
        case .steps: return .stepCount
        case .activeEnergy: return .activeEnergyBurned
        case .restingEnergy: return .basalEnergyBurned
        case .heartRate: return .heartRate
        case .restingHeartRate: return .restingHeartRate
        case .hrv: return .heartRateVariabilitySDNN
        case .bodyMass: return .bodyMass
        case .bodyFat: return .bodyFatPercentage
        case .leanBodyMass: return .leanBodyMass
        case .bmi: return .bodyMassIndex
        case .water: return .dietaryWater
        case .vo2max: return .vo2Max
        case .respiratoryRate: return .respiratoryRate
        case .wristTemperature: return .appleSleepingWristTemperature
        case .dietaryEnergy: return .dietaryEnergyConsumed
        case .dietaryProtein: return .dietaryProtein
        case .dietaryCarbs: return .dietaryCarbohydrates
        case .dietaryFat: return .dietaryFatTotal
        case .dietaryFiber: return .dietaryFiber
        case .dietarySugar: return .dietarySugar
        case .dietarySodium: return .dietarySodium
        case .sleep, .workouts: return nil
        }
    }

    static func objectType(for t: HealthMetricType) -> HKObjectType {
        switch t {
        case .sleep: return HKCategoryType(.sleepAnalysis)
        case .workouts: return HKObjectType.workoutType()
        default: return HKQuantityType(quantityIdentifier(for: t)!)
        }
    }

    static let bpm = HKUnit.count().unitDivided(by: .minute())

    // MARK: Authorization

    public func requestAuthorization(read: Set<HealthMetricType>, write: Set<HealthMetricType>) async throws {
        guard isAvailable else { return }
        let readTypes = Set(read.map(Self.objectType(for:)))
        let shareTypes: Set<HKSampleType> = Set(write.filter(\.isWritable).compactMap { Self.objectType(for: $0) as? HKSampleType })
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    // MARK: Daily metrics

    public func dailyMetrics(from: LocalDate, to: LocalDate) async throws -> [DailyMetrics] {
        let start = from.startDate(calendar: calendar)
        let end = to.endDate(calendar: calendar)

        async let steps = collection(.stepCount, .cumulativeSum, unit: .count(), start: start, end: end)
        async let active = collection(.activeEnergyBurned, .cumulativeSum, unit: .kilocalorie(), start: start, end: end)
        async let basal = collection(.basalEnergyBurned, .cumulativeSum, unit: .kilocalorie(), start: start, end: end)
        async let water = collection(.dietaryWater, .cumulativeSum, unit: .literUnit(with: .milli), start: start, end: end)
        async let rhr = collection(.restingHeartRate, .discreteAverage, unit: Self.bpm, start: start, end: end)
        async let hrv = collection(.heartRateVariabilitySDNN, .discreteAverage, unit: .secondUnit(with: .milli), start: start, end: end)
        async let resp = collection(.respiratoryRate, .discreteAverage, unit: Self.bpm, start: start, end: end)
        async let vo2 = collection(.vo2Max, .discreteAverage, unit: HKUnit(from: "ml/kg*min"), start: start, end: end)
        async let temp = collection(.appleSleepingWristTemperature, .discreteAverage, unit: .degreeCelsius(), start: start.addingTimeInterval(-28 * 86_400), end: end)
        async let sleep = sleepByNight(start: start, end: end)

        let (s, a, b, w, r, h, rr, v, t, sl) = try await (steps, active, basal, water, rhr, hrv, resp, vo2, temp, sleep)
        // Wrist temperature is absolute; docs/02 stores it relative to the user's baseline (28-day mean).
        let tempBaseline = t.isEmpty ? nil : t.values.reduce(0, +) / Double(t.count)

        return LocalDate.range(from: from, through: to).compactMap { day in
            var m = MetricValues()
            m.steps = s[day]; m.activeKcal = a[day]; m.restingKcal = b[day]; m.waterMl = w[day]
            m.restingHr = r[day]; m.hrvMs = h[day]; m.respiratoryRate = rr[day]; m.vo2max = v[day]
            if m.hrvMs != nil { m.hrvMethod = "sdnn" }
            if let tv = t[day], let base = tempBaseline { m.tempDeviationC = ((tv - base) * 100).rounded() / 100 }
            if let night = sl[day] {
                m.sleepStages = night.stages
                m.sleepMinutes = night.stages.asleepMin
                m.bedtimeStart = night.bedtime
            }
            let hasAny = MetricKey.allCases.contains { m.has($0) }
            return hasAny ? DailyMetrics(date: day, source: .healthkit, metrics: m) : nil
        }
    }

    /// One value per local day using `HKStatisticsCollectionQueryDescriptor`.
    private func collection(_ id: HKQuantityTypeIdentifier, _ options: HKStatisticsOptions, unit: HKUnit,
                            start: Date, end: Date) async throws -> [LocalDate: Double] {
        let type = HKQuantityType(id)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: predicate),
            options: options,
            anchorDate: calendar.startOfDay(for: start),
            intervalComponents: DateComponents(day: 1))
        let result: HKStatisticsCollection
        do {
            result = try await descriptor.result(for: store)
        } catch let error as HKError where error.code == .errorNoData || error.code == .errorAuthorizationNotDetermined {
            return [:]
        }
        var out: [LocalDate: Double] = [:]
        for stats in result.statistics() {
            let q = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
            if let q { out[LocalDate(stats.startDate, calendar: calendar)] = q.doubleValue(for: unit) }
        }
        return out
    }

    /// Sleep stages per night, attributed to the local date the user woke up.
    /// When several apps write sleep (e.g. Apple Watch + Oura app), the source with the most asleep time
    /// per night is used to avoid double counting.
    private func sleepByNight(start: Date, end: Date) async throws -> [LocalDate: (stages: SleepStages, bedtime: Date?)] {
        let predicate = HKQuery.predicateForSamples(withStart: start.addingTimeInterval(-12 * 3600), end: end)
        let descriptor = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        let samples = try await descriptor.result(for: store)
        var bySourceNight: [LocalDate: [String: SleepStages]] = [:]
        var bedtimes: [LocalDate: [String: Date]] = [:]
        for sample in samples {
            let night = LocalDate(sample.endDate, calendar: calendar)
            let source = sample.sourceRevision.source.bundleIdentifier
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            let startHour = calendar.component(.hour, from: sample.startDate)
            let isNap = (10..<18).contains(startHour)
            var stages = bySourceNight[night]?[source] ?? SleepStages()
            if !isNap, sample.value != HKCategoryValueSleepAnalysis.awake.rawValue, sample.value != HKCategoryValueSleepAnalysis.inBed.rawValue {
                let current = bedtimes[night]?[source]
                if current == nil || sample.startDate < current! { bedtimes[night, default: [:]][source] = sample.startDate }
            }
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepCore?: if isNap { stages.napMin += minutes } else { stages.coreMin += minutes }
            case .asleepDeep?: if isNap { stages.napMin += minutes } else { stages.deepMin += minutes }
            case .asleepREM?: if isNap { stages.napMin += minutes } else { stages.remMin += minutes }
            case .asleepUnspecified?: if isNap { stages.napMin += minutes } else { stages.unspecifiedMin += minutes }
            case .awake?: stages.awakeMin += minutes
            case .inBed?: stages.inBedMin += minutes
            default: break
            }
            bySourceNight[night, default: [:]][source] = stages
        }
        var out: [LocalDate: (stages: SleepStages, bedtime: Date?)] = [:]
        for (night, sources) in bySourceNight {
            guard let best = sources.max(by: { $0.value.asleepMin < $1.value.asleepMin }) else { continue }
            out[night] = (best.value, bedtimes[night]?[best.key])
        }
        return out
    }

    // MARK: Workouts

    public func workouts(from: LocalDate, to: LocalDate) async throws -> [Workout] {
        let predicate = HKQuery.predicateForSamples(withStart: from.startDate(calendar: calendar), end: to.endDate(calendar: calendar))
        let descriptor = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\.startDate)])
        let workouts = try await descriptor.result(for: store)
        return workouts.map { w in
            let kcal = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity()?.doubleValue(for: .kilocalorie())
            let hr = w.statistics(for: HKQuantityType(.heartRate))
            return Workout(id: w.uuid.uuidString.lowercased(), start: w.startDate, end: w.endDate,
                           type: Self.name(for: w.workoutActivityType), source: .healthkit, durationMin: w.duration / 60,
                           activeKcal: kcal, avgHr: hr?.averageQuantity()?.doubleValue(for: Self.bpm),
                           maxHr: hr?.maximumQuantity()?.doubleValue(for: Self.bpm),
                           distanceM: w.totalDistance?.doubleValue(for: .meter()), externalId: w.uuid.uuidString)
        }
    }

    static func name(for type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .rowing: return "rowing"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .traditionalStrengthTraining: return "traditional_strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .highIntensityIntervalTraining: return "high_intensity_interval_training"
        case .crossTraining: return "cross_training"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stair_climbing"
        case .dance: return "dance"
        case .soccer: return "soccer"
        case .tennis: return "tennis"
        case .basketball: return "basketball"
        case .coreTraining: return "core_training"
        case .mixedCardio: return "mixed_cardio"
        default: return "other"
        }
    }

    // MARK: Body

    public func bodyMeasurements(from: LocalDate, to: LocalDate) async throws -> [BodyMeasurement] {
        let predicate = HKQuery.predicateForSamples(withStart: from.startDate(calendar: calendar), end: to.endDate(calendar: calendar))
        async let mass = samples(.bodyMass, predicate)
        async let fat = samples(.bodyFatPercentage, predicate)
        async let lean = samples(.leanBodyMass, predicate)
        async let bmi = samples(.bodyMassIndex, predicate)
        let (m, f, l, b) = try await (mass, fat, lean, bmi)

        // Merge samples taken within the same minute by the same source into one measurement.
        struct Key: Hashable { var minute: Int; var source: String }
        var grouped: [Key: BodyMeasurement] = [:]
        func key(_ s: HKQuantitySample) -> Key { Key(minute: Int(s.startDate.timeIntervalSince1970 / 60), source: s.sourceRevision.source.bundleIdentifier) }
        func entry(_ s: HKQuantitySample) -> BodyMeasurement {
            grouped[key(s)] ?? BodyMeasurement(id: s.uuid.uuidString.lowercased(), measuredAt: s.startDate, source: "healthkit:\(s.sourceRevision.source.name)")
        }
        for s in m { var e = entry(s); e.weightKg = s.quantity.doubleValue(for: .gramUnit(with: .kilo)); grouped[key(s)] = e }
        for s in f { var e = entry(s); e.bodyFatPct = s.quantity.doubleValue(for: .percent()) * 100; grouped[key(s)] = e }
        for s in l { var e = entry(s); e.leanMassKg = s.quantity.doubleValue(for: .gramUnit(with: .kilo)); grouped[key(s)] = e }
        for s in b { var e = entry(s); e.bmi = s.quantity.doubleValue(for: .count()); grouped[key(s)] = e }
        return grouped.values.sorted { $0.measuredAt < $1.measuredAt }
    }

    private func samples(_ id: HKQuantityTypeIdentifier, _ predicate: NSPredicate) async throws -> [HKQuantitySample] {
        let d = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(id), predicate: predicate)],
                                        sortDescriptors: [SortDescriptor(\.startDate)])
        return try await d.result(for: store)
    }

    // MARK: Writes

    public func save(bodyMeasurement b: BodyMeasurement) async throws {
        var objects: [HKObject] = []
        let meta: [String: Any] = [HKMetadataKeySyncIdentifier: "body-\(b.id)", HKMetadataKeySyncVersion: 1]
        if let kg = b.weightKg {
            objects.append(HKQuantitySample(type: HKQuantityType(.bodyMass), quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: kg),
                                            start: b.measuredAt, end: b.measuredAt, metadata: meta.merging([HKMetadataKeySyncIdentifier: "body-mass-\(b.id)"]) { $1 }))
        }
        if let pct = b.bodyFatPct {
            objects.append(HKQuantitySample(type: HKQuantityType(.bodyFatPercentage), quantity: HKQuantity(unit: .percent(), doubleValue: pct / 100),
                                            start: b.measuredAt, end: b.measuredAt, metadata: meta.merging([HKMetadataKeySyncIdentifier: "body-fat-\(b.id)"]) { $1 }))
        }
        guard !objects.isEmpty else { return }
        try await store.save(objects)
    }

    /// Writes a meal as an `HKCorrelation` of type `.food`. The sync identifier + version make edits replace
    /// the previous copy instead of duplicating it.
    public func save(meal: Meal) async throws {
        guard !meal.deleted, let foodType = HKObjectType.correlationType(forIdentifier: .food) else { return }
        let t = meal.totals
        let date = meal.loggedAt
        func sample(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double) -> HKQuantitySample? {
            guard value > 0 else { return nil }
            return HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: date, end: date)
        }
        let list: [HKSample] = [
            sample(.dietaryEnergyConsumed, .kilocalorie(), t.kcal),
            sample(.dietaryProtein, .gram(), t.proteinG),
            sample(.dietaryCarbohydrates, .gram(), t.carbsG),
            sample(.dietaryFatTotal, .gram(), t.fatG),
            sample(.dietaryFiber, .gram(), t.fiberG),
            sample(.dietarySugar, .gram(), t.sugarG),
            sample(.dietarySodium, .gramUnit(with: .milli), t.sodiumMg),
        ].compactMap { $0 }
        let samples = Set(list)
        guard !samples.isEmpty else { return }
        let name = meal.items.map(\.name).prefix(3).joined(separator: ", ")
        let correlation = HKCorrelation(type: foodType, start: date, end: date, objects: samples, metadata: [
            HKMetadataKeyFoodType: name.isEmpty ? meal.category.displayName : name,
            HKMetadataKeySyncIdentifier: "meal-\(meal.id)",
            HKMetadataKeySyncVersion: max(1, meal.version + 1),
        ])
        try await store.save(correlation)
    }

    public func save(waterMl: Double, at date: Date) async throws {
        let s = HKQuantitySample(type: HKQuantityType(.dietaryWater), quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: waterMl),
                                 start: date, end: date)
        try await store.save(s)
    }

    // MARK: Background delivery

    /// Registers `HKObserverQuery`s and `enableBackgroundDelivery` for the key types. HealthKit relaunches the
    /// app in the background when new samples arrive; `onUpdate` should upsert `/v1/metrics/daily`, `/v1/body`
    /// and `/v1/workouts` (debounced by the caller). The completion handler is always called.
    public func startBackgroundDelivery(onUpdate: @escaping @Sendable () async -> Void) async {
        guard isAvailable else { return }
        let types: [(HKSampleType, HKUpdateFrequency)] = [
            (HKQuantityType(.stepCount), .hourly),
            (HKQuantityType(.activeEnergyBurned), .hourly),
            (HKQuantityType(.bodyMass), .immediate),
            (HKQuantityType(.heartRateVariabilitySDNN), .hourly),
            (HKQuantityType(.restingHeartRate), .hourly),
            (HKCategoryType(.sleepAnalysis), .hourly),
            (HKObjectType.workoutType(), .immediate),
        ]
        let alreadyRunning = lock.withLock { !observerQueries.isEmpty }
        guard !alreadyRunning else { return }
        for (type, frequency) in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                guard error == nil else { completion(); return }
                Task {
                    await onUpdate()
                    completion()
                }
            }
            store.execute(query)
            lock.withLock { observerQueries.append(query) }
            try? await store.enableBackgroundDelivery(for: type, frequency: frequency)
        }
    }
}
#endif
