# 3 · API Architecture

> **Source of truth** for the HTTP contract between the iOS app (`APIClient`) and the
> Lambda backend (`backend/src/handlers/*`).

## 3.1 Topology

```
iOS app ──HTTPS──▶ API Gateway (HTTP API, /v1) ──JWT authorizer (Cognito User Pool)──▶ Lambda (Node.js 22, arm64)
                                                                                      │
             ┌────────────────────────────────────────────────────────────────────────┼──────────────────────┐
             ▼                    ▼                     ▼                    ▼          ▼                      ▼
        DynamoDB            S3 (media)            KMS (CMK)           Bedrock       Secrets Manager      USDA FDC / OFF
     HealthAppData        presigned PUT/GET     table + token key   (Claude vision)  Oura client secret,   (outbound HTTPS)
     HealthAppFoodCatalog                                                             FDC API key
EventBridge Scheduler ─▶ ouraSyncScheduled (hourly) · notificationsScheduled (every 15 min) · tombstonePurge (daily)
Oura webhooks ─▶ POST /v1/webhooks/oura (public, signature-verified) ─▶ SQS ─▶ ouraWebhookWorker
```

* **Auth**: Cognito User Pool with **Sign in with Apple** as a federated IdP. The app uses the Cognito Hosted UI
  (`/oauth2/authorize?identity_provider=SignInWithApple`, PKCE) via `ASWebAuthenticationSession`, receives
  `id_token`/`access_token`/`refresh_token`, stores them in the Keychain. API Gateway validates the **access token**
  (`aud` = app client id). `sub` from the JWT is the only user identifier the backend trusts.
* **Transport**: TLS 1.2+, JSON bodies, `Content-Type: application/json`, ISO-8601 UTC timestamps, dates as `yyyy-mm-dd` in the user's timezone.
* **Errors**: `{ "error": { "code": "VALIDATION_ERROR", "message": "…", "details": {…} } }` with 400/401/403/404/409/413/422/429/500/502.
* **Idempotency**: mutating requests accept `Idempotency-Key` header (the client's entity UUID); writes are upserts keyed on client UUIDs.
* **Versioning**: path prefix `/v1`; additive changes only within a version.
* **Rate limits**: API Gateway stage throttle 20 rps / burst 40 per user route; AI routes 30 requests/hour/user (DynamoDB counter).

## 3.2 Lambda functions (one per bounded context)

| Function | Routes / trigger | Module |
|---|---|---|
| `profileFn` | `/v1/me*`, `/v1/connections*`, `/v1/devices` | auth/profile/permissions |
| `nutritionFn` | `/v1/meals*`, `/v1/foods*`, `/v1/recipes*` | nutrition DB + logging |
| `healthFn` | `/v1/metrics*`, `/v1/body*`, `/v1/workouts*`, `/v1/notes*`, `/v1/cycle*`, `/v1/day/*`, `/v1/trends*` | health data + analytics |
| `aiFn` | `/v1/photos/upload-url`, `/v1/ai/*` | AI food recognition, voice parse, coach |
| `ouraFn` | `/v1/integrations/oura/*`, `/v1/webhooks/oura` | Oura OAuth + sync |
| `syncFn` | `/v1/sync/*` | offline sync |
| `ouraSyncScheduledFn` | EventBridge `rate(1 hour)` | Oura background pull |
| `notificationsScheduledFn` | EventBridge `rate(15 minutes)` | reminders & alerts → SNS mobile push (APNs) |

## 3.3 Endpoints

All routes require `Authorization: Bearer <Cognito access token>` unless marked **public**.

### Profile, goals, permissions
| Method | Path | Body / Query | Response |
|---|---|---|---|
| GET | `/v1/me` | — | `{ profile, goals, connections[] }` |
| PUT | `/v1/me` | `Profile` (partial) | `{ profile }` |
| PUT | `/v1/me/goals` | `Goals` | `{ goals }` |
| DELETE | `/v1/me` | — | `202` — deletes all `USER#` items, S3 prefix, revokes Oura token |
| POST | `/v1/me/export` | — | `{ downloadUrl }` (presigned, 15 min) |
| GET | `/v1/connections` | — | `{ connections[] }` |
| PUT | `/v1/connections/{provider}` | `{ enabledMetrics[], status }` | `{ connection }` — user-level permission switches |
| POST | `/v1/devices` | `{ id, apnsToken, notificationPrefs }` | `{ device }` |

### Nutrition
| Method | Path | Body / Query | Response |
|---|---|---|---|
| GET | `/v1/meals` | `from`, `to` (dates) | `{ meals[] }` |
| PUT | `/v1/meals/{id}` | `Meal` (client UUID, upsert, `version` for concurrency) | `{ meal }` (server recomputes `totals`) |
| DELETE | `/v1/meals/{id}` | — | `204` (tombstone) |
| GET | `/v1/foods/search` | `q`, `limit≤25` | `{ foods: FoodSummary[] }` (USDA FDC + user custom foods) |
| GET | `/v1/foods/barcode/{gtin}` | — | `{ food }` or 404 |
| GET | `/v1/foods/{db}/{id}` | — | `{ food: FoodDetail }` (nutrients per 100 g + portions) |
| PUT | `/v1/foods/custom/{id}` | `CustomFood` | `{ food }` |
| GET/PUT/DELETE | `/v1/recipes[/{id}]` | `Recipe` | `{ recipe(s) }` |

### Health data
| Method | Path | Body / Query | Response |
|---|---|---|---|
| POST | `/v1/metrics/daily` | `{ days: [{ date, source, metrics }] }` (batch ≤ 31) | `{ upserted }` |
| GET | `/v1/metrics/daily` | `from`, `to` | `{ days: [{ date, merged, bySource }] }` |
| POST | `/v1/body` | `{ measurements: BodyMeasurement[] }` | `{ upserted }` |
| GET | `/v1/body` | `from`, `to` | `{ measurements[] }` |
| POST | `/v1/workouts` | `{ workouts: Workout[] }` | `{ upserted }` |
| GET | `/v1/workouts` | `from`, `to` | `{ workouts[] }` |
| PUT | `/v1/notes/{date}` | `{ text, tags[] }` | `{ note }` |
| PUT | `/v1/cycle/{date}` | `CycleEntry` | `{ entry }` (403 unless opted in) |
| GET | `/v1/day/{date}` | — | `DaySummary` — meals, macro totals, workouts, merged metrics, body, note, energy balance, insights |
| GET | `/v1/trends/{metric}` | `range=7d|30d|90d|1y`, `agg=day|week` | `{ metric, unit, points:[{date,value}], avg, min, max, delta }` |
| GET | `/v1/trends/compare` | `x`, `y`, `range`, `lagDays=0|1` | `{ x, y, pairs:[{date,x,y}], pearsonR, n, caveat }` |

Trend metric ids: `weight, bodyFatPct, muscleMassKg, kcalIn, proteinG, carbsG, fatG, fiberG, sleepScore, sleepMinutes, hrvMs, restingHr, readinessScore, activityScore, steps, activeKcal, workoutMinutes, trainingLoad, cycleDay`.

### AI
| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/photos/upload-url` | `{ mealId, contentType: "image/jpeg" }` | `{ uploadUrl, photoKey, expiresIn }` |
| POST | `/v1/ai/meal-analysis` | `{ photoKey, scaleReadings?: [{ grams, label? }], hint?, mealCategory? }` | `MealAnalysis` (below) |
| POST | `/v1/ai/voice-parse` | `{ transcript, mealCategory? }` | `{ items: AnalyzedItem[] }` |
| POST | `/v1/ai/coach` | `{ conversationId, message }` | `{ reply, citations: [{ metric, from, to }], disclaimer? }` |

```jsonc
// MealAnalysis
{
  "analysisId": "…",
  "items": [{
    "id": "i1", "name": "white rice, cooked", "confidence": 0.78,
    "foodRef": { "db": "usda", "id": "169757" },
    "grams": 180, "gramsLow": 130, "gramsHigh": 240,
    "weightSource": "estimated",            // "scale" when a scale reading was matched
    "nutrients": { "kcal": 234, "proteinG": 4.9, "carbsG": 50.8, "fatG": 0.5, "fiberG": 0.7, "sugarG": 0.1, "sodiumMg": 2 },
    "range": { "kcalLow": 169, "kcalHigh": 312 },
    "alternatives": [{ "name": "jasmine rice, cooked", "foodRef": {…} }]
  }],
  "totals": {…}, "totalsRange": { "kcalLow": 480, "kcalHigh": 760 },
  "isEstimate": true,
  "questions": ["Was the chicken cooked with oil or butter?"],
  "model": "anthropic.claude-opus-5-5"
}
```
Nutrients are **always computed server-side from the nutrition database × grams**; the model only identifies foods and estimates grams with a range. When `scaleReadings` are present, matched items get `weightSource: "scale"` and `gramsLow = gramsHigh = grams`.

### Oura
| Method | Path | Body | Response |
|---|---|---|---|
| POST | `/v1/integrations/oura/authorize` | — | `{ authorizeUrl }` (state + PKCE stored in `OAUTHSTATE#`) |
| GET | `/v1/integrations/oura/callback` **public** | `code`, `state` | `302 → healthapp://oura/connected` or `healthapp://oura/error?reason=` |
| POST | `/v1/integrations/oura/sync` | `{ from?, to? }` | `{ daysUpserted, workoutsUpserted }` |
| DELETE | `/v1/integrations/oura` | — | `204` — revokes token, marks connection revoked |
| POST | `/v1/webhooks/oura` **public** | Oura event | `200` (HMAC `x-oura-signature` verified) |
| GET | `/v1/webhooks/oura` **public** | `verification_token`, `challenge` | `{ challenge }` |

### Sync (offline-first)
| Method | Path | Body / Query | Response |
|---|---|---|---|
| POST | `/v1/sync/push` | `{ changes: [{ entityType, id, op: "upsert"|"delete", baseVersion, data }] }` (≤ 100) | `{ results: [{ id, status: "applied"|"conflict", serverVersion, serverItem? }] }` |
| GET | `/v1/sync/pull` | `since=<cursor>`, `limit≤200` | `{ changes: [{ entityType, id, deleted, version, data }], cursor, hasMore }` |

## 3.6 Offline sync algorithm

1. Every local write goes to SwiftData **and** appends a `PendingChange` (outbox) row with the entity snapshot and `baseVersion`.
2. `SyncEngine` drains the outbox when `NWPathMonitor` reports connectivity, on app foreground, and in a `BGAppRefreshTask`.
3. Server applies each change with a conditional write `attribute_not_exists(PK) OR version = :baseVersion`.
   On conflict it returns the server item; the client resolves with **field-level last-writer-wins for meals**
   (items merged by item `id`, newest `updatedAt` wins) and server-wins for everything else, then re-queues.
4. After push, client calls `/sync/pull?since=<cursor>` (cursor = last `GSI1SK` seen) and applies remote changes.
5. HealthKit-derived data is **not** pushed through the outbox; it is re-derivable and is upserted via `/metrics/daily`, `/body`, `/workouts` in idempotent batches keyed by HealthKit UUID.

## 3.7 Security controls

* JWT authorizer on every non-public route; handlers derive `sub` only from `requestContext.authorizer.jwt.claims.sub`.
* IAM least privilege per function (e.g. `aiFn` can `bedrock:InvokeModel` + read `users/*/meals/*` in S3; it cannot read tokens).
* DynamoDB `LeadingKeys` is enforced in code — every key builder takes `sub` and prefixes `USER#`.
* Oura webhook: HMAC-SHA256 signature check with the client secret + timestamp skew ≤ 5 min.
* Bedrock prompts contain only the photo and food-level context — no name, email or Apple ID.
* CloudWatch logs scrub bodies (structured logger logs route, status, latency, `sub` hash only). 30-day log retention.
* WAF (prod) with AWS managed rule groups on the API stage.
