# 2 · Database Schema (DynamoDB)

> **Source of truth.** The backend (`backend/src/lib/keys.js`) and the iOS sync layer
> (`ios/Packages/HealthAppKit/Sources/SyncKit`) both follow this document.

## 2.1 Design principles

| Principle | How |
|---|---|
| One table per bounded context, single-table design inside it | `HealthAppData` (all per-user data), `HealthAppFoodCatalog` (shared nutrition cache) |
| Every user item lives under one partition | `PK = USER#<cognitoSub>` — makes "export my data" and "delete my account" a single `Query` |
| Time-ordered sort keys | ISO-8601 dates/timestamps in `SK` so range queries (`BETWEEN`) give calendar/trend windows |
| Offline-first sync | Every user item carries `updatedAt`, `version`, `deleted` (tombstone), and `GSI1` keys for "changes since cursor" |
| Encryption | Table encrypted with a customer-managed KMS key (CMK). OAuth tokens are additionally envelope-encrypted per item with a separate KMS key (`tokenCiphertext`) |
| Recovery | Point-in-time recovery on; deletion protection on in prod |
| Data minimisation | Meal photos live in S3 (not DynamoDB), expire after 30 days unless the user pins them |
| TTL | `expiresAt` (epoch seconds) for analysis jobs, OAuth state, food cache entries |

## 2.2 Table `HealthAppData`

| Attribute | Type | Notes |
|---|---|---|
| `PK` | S | Partition key |
| `SK` | S | Sort key |
| `GSI1PK` | S | `USER#<sub>` for syncable items |
| `GSI1SK` | S | `UPD#<updatedAt ISO>#<entityType>#<id>` — monotonically sortable change feed |
| `entityType` | S | `profile`, `goals`, `connection`, `meal`, `dailyMetrics`, `body`, `workout`, `customFood`, `recipe`, `note`, `cycle`, `device`, `analysis`, `chat` |
| `id` | S | UUID v4 (client-generated for offline creation) |
| `updatedAt` | S | ISO-8601 UTC, server-stamped on write |
| `version` | N | Optimistic-concurrency counter (conditional write `version = :expected`) |
| `deleted` | BOOL | Tombstone; `expiresAt` set to +90 days on delete so TTL purges it (the daily `tombstonePurge` job is a backstop + orphaned-photo cleanup) |
| `expiresAt` | N | TTL (optional) |

**GSI1** (`GSI1PK`, `GSI1SK`, projection ALL) — the sync change feed.
**GSI2** (`GSI2PK = OURAUSER#<ouraUserId>`, `GSI2SK = CONNECTION`) — maps Oura webhook events back to our user. Sparse (only connection items).

### 2.2.1 Item types & key patterns

| Entity | PK | SK | Key attributes |
|---|---|---|---|
| Profile | `USER#<sub>` | `PROFILE` | `displayName, birthYear, sex, heightCm, units ("metric"/"imperial"), timezone, cycleTrackingEnabled, createdAt` |
| Goals | `USER#<sub>` | `GOALS` | `calorieTarget?, proteinG, carbsG, fatG, fiberG, waterMl, stepGoal, sleepHours, mode ("maintain"/"gain"/"lose_gently"/"performance")` |
| Source permission / connection | `USER#<sub>` | `CONNECTION#<provider>` | `provider ("healthkit","oura","bodyscale:<id>","foodscale:<id>")`, `status ("connected","revoked","error")`, `scopes[]`, `enabledMetrics[]`, `lastSyncAt`, `lastError?`, `tokenCiphertext?` (Oura only, KMS-encrypted JSON `{access_token, refresh_token, expires_at}`), `ouraUserId?`, `GSI2PK?` |
| Meal | `USER#<sub>` | `MEAL#<yyyy-mm-dd>#<mealId>` | see 2.2.2 |
| Daily metrics | `USER#<sub>` | `DAY#<yyyy-mm-dd>#<source>` | `date, source ("healthkit"/"oura"/"manual")`, `metrics` map (see 2.2.3) |
| Body measurement | `USER#<sub>` | `BODY#<ISO timestamp>#<id>` | `measuredAt, source, weightKg?, bodyFatPct?, leanMassKg?, muscleMassKg?, bmi?, visceralFat?, waterPct?, boneMassKg?, bmrKcal?` — HealthKit `leanBodyMass` → `leanMassKg`; scale-reported skeletal/muscle mass → `muscleMassKg` (different measures, never merged) |
| Workout | `USER#<sub>` | `WORKOUT#<ISO start>#<id>` | `start, end, type, source, durationMin, activeKcal?, avgHr?, maxHr?, distanceM?, strain/load (TRIMP)?, externalId` |
| Custom food | `USER#<sub>` | `FOOD#<id>` | `name, brand?, servingG, nutrientsPer100g` |
| Recipe / saved meal | `USER#<sub>` | `RECIPE#<id>` | `name, kind ("recipe"/"savedMeal"), items[] (FoodItem), totalCookedWeightG?, servings` |
| Note | `USER#<sub>` | `NOTE#<yyyy-mm-dd>` | `text, tags[]` |
| Cycle entry (opt-in) | `USER#<sub>` | `CYCLE#<yyyy-mm-dd>` | `flow?, phase?, symptoms[]` — only written when `profile.cycleTrackingEnabled` |
| Device | `USER#<sub>` | `DEVICE#<id>` | `apnsToken, platform, appVersion, notificationPrefs` |
| Meal analysis job | `USER#<sub>` | `ANALYSIS#<id>` | `photoKey, status, result, model, createdAt, expiresAt (+7d)` |
| Coach message | `USER#<sub>` | `CHAT#<conversationId>#<ISO ts>` | `role, text, citations[]` , `expiresAt (+90d)` |
| OAuth state | `OAUTHSTATE#<state>` | `STATE` | `sub, codeVerifier?, provider, expiresAt (+10 min)` (PKCE verifier only if the provider supports PKCE; the server-side client secret protects the exchange regardless) |
| AI rate counter | `USER#<sub>` | `RATE#ai#<yyyy-mm-ddThh>` | `count`, `expiresAt (+2h)` — 30 AI calls / user / hour |
| Notification log | `USER#<sub>` | `NOTIFLOG#<kind>#<yyyy-mm-dd>` | `sentAt`, `expiresAt (+14d)` — de-duplicates reminders |
| Oura app-wide rate window | `SYSTEM#oura` | `RATE#<window>` | `count`, `expiresAt` — protects the shared Oura client quota |

### 2.2.2 Meal item

```jsonc
{
  "PK": "USER#9f1c…", "SK": "MEAL#2026-10-03#7b0e…",
  "entityType": "meal", "id": "7b0e…",
  "date": "2026-10-03", "loggedAt": "2026-10-03T12:41:00Z",
  "category": "lunch",                // breakfast | lunch | dinner | snack | drink
  "source": "photo",                  // photo | scale | barcode | search | voice | recipe | restaurant | custom | manual
  "photoKey": "users/9f1c…/meals/7b0e….jpg",
  "items": [
    {
      "id": "a1",
      "name": "Grilled chicken breast",
      "foodRef": { "db": "usda", "id": "171477" },   // usda | off | custom | recipe | ai
      "grams": 142,
      "weightSource": "scale",          // scale | estimated | user | label
      "confidence": 0.86,               // AI recognition confidence (0-1), null for non-AI
      "nutrients": { "kcal": 234, "proteinG": 44.0, "carbsG": 0, "fatG": 5.1,
                     "fiberG": 0, "sugarG": 0, "sodiumMg": 104 },
      "range": { "kcalLow": 234, "kcalHigh": 234 }  // equal when weighed
    }
  ],
  "totals": { "kcal": 612, "proteinG": 52, "carbsG": 61, "fatG": 17,
              "fiberG": 7, "sugarG": 6, "sodiumMg": 790 },
  "totalsRange": { "kcalLow": 540, "kcalHigh": 700 },
  "isEstimate": true,
  "notes": "Restaurant: …",
  "updatedAt": "2026-10-03T12:42:10Z", "version": 3, "deleted": false,
  "GSI1PK": "USER#9f1c…", "GSI1SK": "UPD#2026-10-03T12:42:10Z#meal#7b0e…"
}
```

### 2.2.3 Daily metrics map (normalised across sources)

| Key | Unit | HealthKit | Oura |
|---|---|---|---|
| `steps` | count | `stepCount` | `daily_activity.steps` |
| `activeKcal` | kcal | `activeEnergyBurned` | `daily_activity.active_calories` |
| `restingKcal` | kcal | `basalEnergyBurned` | — (derived: `total_calories − active_calories`) |
| `restingHr` | bpm | `restingHeartRate` | `sleep.lowest_heart_rate` — stored with `restingHrMethod: "sleepLowest"`; not identical to Apple's measure, so trends never mix sources |
| `hrvMs` | ms | `heartRateVariabilitySDNN` | `sleep.average_hrv` (RMSSD) — stored with `hrvMethod` |
| `sleepMinutes` | min | `sleepAnalysis` (asleep*) | `sleep.total_sleep_duration / 60` |
| `sleepStages` | min map `{coreMin, deepMin, remMin, awakeMin, unspecifiedMin, inBedMin, napMin}` | `asleepCore/Deep/REM/Unspecified`, `awake`, `inBed` | `light→coreMin`, `deep`, `rem`, `awake_time` |
| `sleepScore` | 0-100 | — | `daily_sleep.score` |
| `readinessScore` | 0-100 | — | `daily_readiness.score` |
| `activityScore` | 0-100 | — | `daily_activity.score` |
| `tempDeviationC` | °C | `appleSleepingWristTemperature` (baseline-relative) | `daily_readiness.temperature_deviation` |
| `respiratoryRate` | br/min | `respiratoryRate` | `sleep.average_breath` |
| `spo2Pct` | % | `oxygenSaturation` | `daily_spo2.spo2_percentage.average` |
| `waterMl` | ml | `dietaryWater` | — |
| `vo2max` | ml/kg/min | `vo2Max` | — |

**Source precedence** when two sources provide the same metric is decided client- and server-side by `services/merge.js`: user override → Oura for sleep/readiness/HRV/temperature → HealthKit for steps/energy/workouts/body. Users can change precedence in Settings → Data Sources.

## 2.3 Table `HealthAppFoodCatalog` (shared cache, no PII)

| Entity | PK | SK | Notes |
|---|---|---|---|
| USDA food | `FDC#<fdcId>` | `FOOD` | Normalised `nutrientsPer100g`, `portions[]`, `dataType`, `expiresAt` (+30d) |
| Barcode | `GTIN#<gtin14>` | `FOOD` | `fdcId` or Open Food Facts payload, `expiresAt` (+30d) |
| Search cache | `SEARCH#<normalisedQuery>` | `RESULT` | Top 25 hits, `expiresAt` (+1d) |

## 2.4 S3 layout (bucket `healthapp-<stage>-user-media`)

```
users/<sub>/meals/<mealId>.jpg        # SSE-KMS, lifecycle: delete after 30 days unless tag pinned=true
users/<sub>/exports/<ts>.zip          # data export, delete after 7 days
```
Block-public-access on, TLS-only bucket policy, presigned PUT (5 min, `image/jpeg`) only. A presigned PUT cannot enforce size, so `aiFn` checks `ContentLength ≤ 8 MB` and the JPEG magic bytes before calling the model (switch to a presigned POST policy if a hard upload cap is needed).

## 2.5 On-device store (SwiftData, iOS)

The iOS app mirrors the user-owned entities above as SwiftData models (`MealEntity`, `FoodItemEntity`, `DailyMetricsEntity`, `BodyMeasurementEntity`, `WorkoutEntity`, `NoteEntity`, `PendingChange`).
The store file uses `NSFileProtectionComplete`; OAuth/Cognito tokens live in the Keychain
(`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). `PendingChange` is the outbox for offline logging (see API §3.6).
