# 4 · HealthKit Data Model

> How `HealthKitModule` (iOS package `HealthAppKit/Sources/HealthKitModule`) reads and writes Apple Health,
> and how HealthKit data maps to `DailyMetrics` keys (schema §2.2.3), `BodyMeasurement` and `Workout` items.
> Minimum deployment target: **iOS 17**. API availability notes are as of iOS 17/18 — verify against current Apple docs.

## 4.1 Types read

Aggregation column: **cumulative** → `HKStatisticsOptions.cumulativeSum`; **discrete** → `.discreteAverage` / `.discreteMin` / `.discreteMax` / `.mostRecent`.

### Quantity types (`HKQuantityTypeIdentifier`)

| Identifier | HKUnit string | Aggregation (options) | Our field | Background delivery |
|---|---|---|---|---|
| `stepCount` | `count` | cumulative (`.cumulativeSum`) | `metrics.steps` | `.hourly` |
| `activeEnergyBurned` | `kcal` | cumulative | `metrics.activeKcal` | `.hourly` |
| `basalEnergyBurned` | `kcal` | cumulative | `metrics.restingKcal` | `.daily` |
| `restingHeartRate` | `count/min` | discrete (`.discreteAverage`; one sample/day typical) | `metrics.restingHr` | `.daily` |
| `heartRateVariabilitySDNN` | `ms` | discrete (`.discreteAverage`) | `metrics.hrvMs` (`hrvMethod: "sdnn"`) | `.daily` |
| `heartRate` | `count/min` | discrete (`.discreteAverage`, `.discreteMax`) — used for workout avg/max only | `Workout.avgHr / maxHr` | — (queried per workout) |
| `respiratoryRate` | `count/min` | discrete (`.discreteAverage`, sleep window) | `metrics.respiratoryRate` | `.daily` |
| `oxygenSaturation` | `%` (fraction 0–1 → ×100) | discrete (`.discreteAverage`, sleep window) | `metrics.spo2Pct` | `.daily` |
| `appleSleepingWristTemperature` (iOS 16+) | `degC` | discrete (`.mostRecent`) — deviation computed vs 30-day personal baseline | `metrics.tempDeviationC` | `.daily` |
| `vo2Max` | `ml/kg*min` | discrete (`.mostRecent`) | `metrics.vo2max` | `.weekly` |
| `dietaryWater` | `mL` | cumulative | `metrics.waterMl` | `.hourly` |
| `bodyMass` | `kg` | discrete (sample-level, not aggregated) | `BodyMeasurement.weightKg` | `.immediate` |
| `bodyFatPercentage` | `%` (fraction → ×100) | discrete sample | `BodyMeasurement.bodyFatPct` | `.immediate` |
| `leanBodyMass` | `kg` | discrete sample | `BodyMeasurement.muscleMassKg` ⚠️ see note | `.immediate` |
| `bodyMassIndex` | `count` | discrete sample | `BodyMeasurement.bmi` | `.immediate` |
| `height` | `cm` | `.mostRecent` | `Profile.heightCm` (prefill only) | — |
| `distanceWalkingRunning` | `m` | cumulative | workout `distanceM` (per-workout) | — |
| `distanceCycling` | `m` | cumulative | workout `distanceM` | — |

> ⚠️ **Lean body mass ≠ muscle mass.** HealthKit has no muscle-mass type. Schema §2.2.1 only has `muscleMassKg`, so we store HealthKit `leanBodyMass` there when `source = "healthkit"`, and the UI labels any HealthKit-sourced value "Lean mass" (see open question in doc 10). Visceral fat, water %, bone mass and BMR have no HealthKit type; they come only from direct BLE/vendor providers (doc 06).

### Category types (`HKCategoryTypeIdentifier`)

| Identifier | Values used | Our field | Background delivery |
|---|---|---|---|
| `sleepAnalysis` | `inBed`, `asleepUnspecified`, `asleepCore`, `asleepDeep`, `asleepREM`, `awake` (stage values iOS 16+) | `metrics.sleepMinutes`, `metrics.sleepStages` | `.daily` (fires on morning sync) |
| `menstrualFlow` (opt-in only) | `unspecified/light/medium/heavy/none` | `CycleEntry.flow` (only when `cycleTrackingEnabled`) | `.daily` |

### Workouts

| Type | Read | Fields |
|---|---|---|
| `HKWorkoutType.workoutType()` | `HKWorkout` + `workoutActivityType`, `startDate`, `endDate`, `duration`, `statistics(for: activeEnergyBurned)`, `statistics(for: heartRate)`, `statistics(for: distance…)` | `Workout { start, end, type (mapped from HKWorkoutActivityType raw → our enum), durationMin, activeKcal, avgHr, maxHr, distanceM, strain/load (TRIMP computed in AnalyticsKit), externalId = HKWorkout.uuid, source = "healthkit" }` |

TRIMP (Banister) uses HR samples during the workout plus profile resting/max HR; computed on-device and uploaded as `load`.

## 4.2 Types written (opt-in: Settings → Data Sources → Apple Health → "Write nutrition")

| Identifier | HKUnit | Written from |
|---|---|---|
| `dietaryEnergyConsumed` | `kcal` | `FoodItem.nutrients.kcal` |
| `dietaryProtein` | `g` | `proteinG` |
| `dietaryCarbohydrates` | `g` | `carbsG` |
| `dietaryFatTotal` | `g` | `fatG` |
| `dietaryFiber` | `g` | `fiberG` |
| `dietarySugar` | `g` | `sugarG` |
| `dietarySodium` | `mg` | `sodiumMg` |
| `dietaryWater` | `mL` | hydration taps on Today |
| `bodyMass`, `bodyFatPercentage` (+ `leanBodyMass`, `bodyMassIndex`) | `kg`, `%`, `kg`, `count` | manual body entries and direct-BLE scale readings (M4) |
| `HKCorrelationType(.food)` | — | one correlation per **FoodItem**, containing the dietary samples above |

### Nutrition write-back structure

```swift
let meta: [String: Any] = [
  HKMetadataKeyFoodType: item.name,                 // "Grilled chicken breast"
  HKMetadataKeyExternalUUID: "\(meal.id):\(item.id)", // stable for idempotent replace
  "com.healthapp.mealId": meal.id.uuidString,
  "com.healthapp.mealCategory": meal.category.rawValue,
  "com.healthapp.isEstimate": meal.isEstimate        // Bool
]
let samples: Set<HKSample> = [energy, protein, carbs, fat, fiber, sugar, sodium] // same start/end = meal.loggedAt
let food = HKCorrelation(type: .correlationType(forIdentifier: .food)!,
                         start: meal.loggedAt, end: meal.loggedAt,
                         objects: samples, metadata: meta)
```

- Each dietary sample carries the same metadata so it can be found without the correlation.
- **Edit/delete**: delete existing objects matching `HKMetadataKeyExternalUUID` prefix `meal.id` (`HKQuery.predicateForObjects(withMetadataKey:allowedValues:)`), then write the new set. Writes happen after local save, never block the UI, and are retried from a small HealthKit write queue.
- We write the **point estimate** (`grams` × nutrients), and flag `isEstimate`; HealthKit has no range concept.
- Our own samples are excluded on read with `NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default()))`.

## 4.3 Mapping to `DailyMetrics`

| `metrics` key | Computation from HealthKit |
|---|---|
| `steps` | `HKStatisticsCollectionQuery` (`.cumulativeSum`, `intervalComponents: day=1`, anchor = local midnight) — HealthKit merges overlapping sources by its source priority |
| `activeKcal` | same, `activeEnergyBurned` |
| `restingKcal` | same, `basalEnergyBurned` |
| `restingHr` | `.discreteAverage` of the day's `restingHeartRate` samples |
| `hrvMs` | `.discreteAverage` of SDNN samples between sleep start and wake (fallback: whole day); `hrvMethod = "sdnn"` |
| `sleepMinutes` | sum of merged `asleep*` intervals for the **sleep session ending** on that date (§4.5) |
| `sleepStages` | `{ coreMin, deepMin, remMin, awakeMin, unspecifiedMin, inBedMin }` |
| `tempDeviationC` | latest wrist temperature − trailing 30-night median (labelled *relative*) |
| `respiratoryRate`, `spo2Pct` | `.discreteAverage` within sleep window |
| `waterMl` | `.cumulativeSum` of `dietaryWater` **including** our own writes (they are genuine user-entered intake — the one exception to the "exclude own source" rule); hydration taps are stored locally and written to HK, never double-counted because the Today value is read back from HK only |
| `vo2max` | `.mostRecent` within the day |

`sleepScore`, `readinessScore`, `activityScore` have no HealthKit equivalent (Oura only).

## 4.4 Dedupe & source priority

1. **Statistics queries** (`HKStatisticsCollectionQuery`) already de-duplicate overlapping samples using the user's **Health app → Data Sources & Access** priority order. We use them for every cumulative daily metric; we never sum raw samples ourselves.
2. **Sample-level types** (body, workouts, sleep) are de-duplicated by us:
   - Key = `HKObject.uuid` (`externalId`); uploads are idempotent upserts.
   - Same measurement written by two apps (e.g. scale app and Health sync app): if two `bodyMass` samples are within **2 minutes** and **0.1 kg**, keep the one whose `sourceRevision.source.bundleIdentifier` ranks higher in our priority list (user-configurable, default: scale vendor apps > Apple Health manual > others).
   - Workouts overlapping by > 80 % of duration from different sources: prefer Apple Watch (`sourceRevision.productType` begins with `Watch`) then user priority; the loser is hidden, not deleted.
   - Sleep: prefer one source per night (§4.5).
3. **Deletions**: anchored queries return `deletedObjects`; we tombstone the corresponding `BODY#`/`WORKOUT#` items and recompute affected days.
4. `HKSourceRevision.version` is recorded for diagnostics; when a source app updates and rewrites samples, new UUIDs arrive via the anchor and old ones as deletions.

## 4.5 Sleep handling

- iOS 16+ stage values: `asleepCore`, `asleepDeep`, `asleepREM`, `asleepUnspecified`, `awake`, `inBed`. Pre-iOS-16 `asleep` is the same raw value as `asleepUnspecified`. (Our minimum is iOS 17, so stages are available; older data may be unspecified-only.)
- **Session**: group samples whose gaps are < 90 min into a session; the session is attributed to the **local date on which it ends** (a night 23:10→07:05 belongs to the morning date). Naps (< 3 h, ending 10:00–20:00) are stored as `sleepStages.napMin` and excluded from `sleepMinutes`.
- **One source per night**: choose the source with stage data (`asleepCore/Deep/REM`) over unspecified; tie-break by user priority. Never merge stages from two devices into one night.
- `sleepMinutes` = Σ asleep* (core + deep + REM + unspecified) of the chosen source, with overlapping intervals unioned. `inBed` is reported separately and never counted as sleep. `awake` within a session → `awakeMin`.
- When Oura is connected and has precedence for sleep (default), HealthKit sleep is still stored under `DAY#…#healthkit` for comparison but not displayed as primary.

## 4.6 Query strategy

| Mechanism | Use |
|---|---|
| `HKObserverQuery` per read type | Wakes the app when new data arrives; registered at launch (in `application(_:didFinishLaunching…)` equivalent, before the first frame) |
| `enableBackgroundDelivery(for:frequency:)` | Frequencies per table §4.1 (`.immediate` body, `.hourly` steps/energy/water, `.daily` sleep/HRV/RHR, `.weekly` VO₂max). Requires the `com.apple.developer.healthkit.background-delivery` entitlement. iOS may coalesce; `.immediate` is a request, not a guarantee. |
| `HKAnchoredObjectQuery` per type | Incremental changes since persisted anchor (`HKQueryAnchor` archived in `LocalStore`); returns `added` + `deletedObjects`. Anchors are saved **only after** the backend upsert succeeds. |
| `HKStatisticsCollectionQuery` | Recompute daily aggregates for the set of local dates touched by anchored results (plus today) |
| `HKSampleQuery` | Workout HR series, sleep window bounded queries |
| Initial backfill | First connection: last **90 days**, newest first, in 31-day `POST /v1/metrics/daily` batches |

Observer completion handlers are always called (even on error) to avoid iOS throttling background delivery. Work in a background wake is time-boxed to ~20 s; unfinished work is deferred to the next `BGAppRefreshTask`.

## 4.7 Authorization UX

- Request **per type, in context**: onboarding "Choose sources" shows each metric with a toggle; only toggled types are passed to `requestAuthorization(toShare:read:)`. Types can be added later from Data Sources.
- **Read denial is undetectable**: `authorizationStatus(for:)` reflects **write** permission only. For reads, a denied type simply returns no samples. Therefore:
  - We never show "permission denied" for reads; we show "No data from Apple Health yet" with a *Check Health permissions* button that deep-links to instructions (Settings → Health → Data Access & Devices → HealthApp).
  - We track `enabledMetrics[]` ourselves (`CONNECTION#healthkit`) as the user's intent.
- `getRequestStatusForAuthorization(toShare:read:)` tells us whether a prompt would be shown (`.shouldRequest`) — used to decide when to re-prompt after adding types.
- Purpose strings are specific: *"HealthApp reads steps, energy, sleep, heart-rate variability, workouts and body measurements to show your daily fuel, training and recovery picture."*
- Health data is unavailable on iPad without Health app (pre-iPadOS 17) — iPhone only for MVP; check `HKHealthStore.isHealthDataAvailable()`.

## 4.8 Timezone & day boundaries

- A "day" is the **local calendar day in the profile's `timezone`** (schema: dates `yyyy-mm-dd` in user timezone).
- Statistics anchor = local midnight computed with `Calendar(identifier: .gregorian)` set to `profile.timezone`.
- **Travel**: when the device timezone differs from `profile.timezone` for > 24 h, we prompt to update the profile timezone; past days are never re-bucketed (stored dates are immutable once a day is > 2 days old).
- Samples carry `HKMetadataKeyTimeZone` where available; for workouts/meals we store UTC timestamps plus the derived local date.
- DST days have 23/25 h; we rely on `Calendar` date arithmetic, never `+86400`.
- Sleep attribution: by session end date (§4.5). Workouts crossing midnight: attributed to the start date.
- Today's data is marked partial until local midnight + 3 h (late-arriving watch sync).

## 4.9 Swift protocol sketch

```swift
import HealthKit
import CoreModels

public enum HealthMetricKind: String, CaseIterable, Sendable {
    case steps, activeEnergy, restingEnergy, restingHeartRate, hrv, respiratoryRate,
         oxygenSaturation, wristTemperature, vo2Max, water, sleep, workouts, body, cycle
}

public struct HealthSyncResult: Sendable {
    public var days: [DailyMetrics]          // source = .healthkit
    public var body: [BodyMeasurement]
    public var workouts: [Workout]
    public var deletedExternalIds: [String]
}

public protocol HealthKitService: Sendable {
    var isAvailable: Bool { get }

    /// Requests read/write access for the given kinds. Cannot report read denials (by design).
    func requestAuthorization(read: Set<HealthMetricKind>, writeNutrition: Bool) async throws
    func authorizationRequestNeeded(for kinds: Set<HealthMetricKind>) async -> Bool

    /// Daily aggregates for [from, to] in the given timezone.
    func dailyMetrics(from: Date, to: Date, timeZone: TimeZone) async throws -> [DailyMetrics]
    func sleepSessions(from: Date, to: Date, timeZone: TimeZone) async throws -> [SleepSession]
    func workouts(from: Date, to: Date) async throws -> [Workout]
    func bodyMeasurements(from: Date, to: Date) async throws -> [BodyMeasurement]

    /// Incremental: runs anchored queries for enabled kinds, returns changes, persists anchors on `commit`.
    func changesSinceLastAnchor(kinds: Set<HealthMetricKind>, timeZone: TimeZone) async throws -> (HealthSyncResult, commit: @Sendable () async -> Void)

    /// Registers HKObserverQuery + enableBackgroundDelivery; handler must finish quickly.
    func startObserving(kinds: Set<HealthMetricKind>, onChange: @escaping @Sendable (HealthMetricKind) async -> Void) async throws
    func stopObserving() async

    // Write-back
    func saveMeal(_ meal: Meal) async throws          // HKCorrelation(.food) per item, idempotent by external UUID
    func deleteMeal(id: UUID) async throws
    func saveWater(ml: Double, at: Date, id: UUID) async throws
    func saveBodyMeasurement(_ m: BodyMeasurement) async throws
}
```

`LiveHealthKitService` wraps `HKHealthStore`; `DemoHealthKitService` (MockData) returns the 90-day demo set so the app runs in Simulator.
