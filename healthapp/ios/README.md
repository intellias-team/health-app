# HealthApp — iOS

Native SwiftUI app (iOS 17+) that unifies Apple Health, Oura Ring, smart body scales, Bluetooth food scales
and AI meal-photo logging into one **Fuel · Train · Recover** dashboard.

* Contract docs: [`../docs/02-database-schema.md`](../docs/02-database-schema.md) (data shapes) and
  [`../docs/03-api-architecture.md`](../docs/03-api-architecture.md) (HTTP API — `Networking/Endpoints.swift` mirrors it route for route).
* Backend: AWS API Gateway (HTTP API) + Lambda; auth via Cognito Hosted UI with Sign in with Apple (PKCE).

## Requirements

| Tool | Version |
|---|---|
| Xcode | 16.0+ (iOS 18 SDK; the iOS 18 `Tab` API is used behind `#available`) |
| iOS deployment target | 17.0 |
| Swift | 6 compiler, **Swift 5 language mode** |
| XcodeGen | 2.38+ |

## Getting started

```bash
brew install xcodegen
cd ios
xcodegen            # generates HealthApp.xcodeproj from project.yml
open HealthApp.xcodeproj
```

Select the **HealthApp** scheme and run on an iPhone simulator. With the default (empty) `Config.xcconfig`
the app starts in **demo mode** — no backend, HealthKit or Oura needed.

### Running in demo mode

Demo mode is chosen automatically when **any** backend value is missing, **or** when running in the Simulator
(override with the launch argument `-HealthAppLiveMode YES`), and always under XCTest.

* `MockData.DemoDataProvider` generates 90 days of consistent data: meals (photo estimates with ranges,
  weighed and label items), Apple Health + Oura daily metrics (with different HRV methods), workouts with
  training load, weight/body composition, notes and an (opt-in) cycle.
* Every screen works: logging (photo analysis returns a sample result, voice parsing is local, barcode
  lookups resolve to demo foods), Trends/Compare, Coach (answers computed from the demo data), Calendar.
* The food scale is simulated in the Simulator (Food → Add → Food scale → *Simulator: place an item*).

### Connecting a backend (live mode)

1. Copy `Config.local.xcconfig.example` to `Config.local.xcconfig` (git-ignored) and fill in:

   | Key | Example |
   |---|---|
   | `API_BASE_URL` | `https:/$()/abc123.execute-api.eu-west-1.amazonaws.com` (xcconfig treats `//` as a comment — keep the `$()`) |
   | `COGNITO_DOMAIN` | `healthapp-dev.auth.eu-west-1.amazoncognito.com` (or just the prefix) |
   | `COGNITO_CLIENT_ID` | public app client id (no secret) |
   | `COGNITO_REGION` | `eu-west-1` |
   | `DEVELOPMENT_TEAM` | your Apple team id |

2. In the Cognito app client allow callback URL `healthapp://auth/callback`, sign-out URL
   `healthapp://auth/signout`, OAuth flow *Authorization code grant*, scopes `openid email profile`, and
   identity provider **SignInWithApple**.
3. `xcodegen` again (values are injected into Info.plist as `API_BASE_URL`, `COGNITO_*`).

### Capabilities to enable (developer portal → Identifiers → your App ID)

* **HealthKit** (Clinical Health Records **off**) + **HealthKit Background Delivery**
* **Sign in with Apple** (also configure the Service ID / key used by Cognito's Apple IdP)
* **Push Notifications** (create an APNs key for SNS mobile push used by `notificationsScheduledFn`)
* **Data Protection** → Complete protection (the entitlement `NSFileProtectionComplete` is set)
* **Associated Domains** — optional, only if you add universal links (commented out in `project.yml`)

Background modes (`fetch`, `processing`, `remote-notification`) and `BGTaskSchedulerPermittedIdentifiers`
(`com.healthapp.ios.refresh`, `com.healthapp.ios.sync-processing`) are declared in `project.yml`.
`bluetooth-central` background mode is intentionally not used (scales are used in the foreground).

## Module map

```
HealthApp (app target, thin)            Composition root + feature UI
  App/AppEnvironment.swift              Chooses Live vs Demo, wires adapters to ports, app-wide state
  Features/{Today,Food,Activity,Recovery,Body,Trends,Coach,Calendar,Settings,Onboarding}

Packages/HealthAppKit (local SwiftPM, one product per module)
  CoreModels         Value types (Meal, FoodItem, Nutrients, DailyMetrics, …) + service protocols ("ports"). No deps.
  AnalyticsKit       Energy balance, neutral fueling insight, stats, Pearson, rolling avg, TRIMP load,
                     source-precedence merge, trend builder, Fuel·Train·Recover composer.   → CoreModels
  Networking         APIClient (async/await, retry/backoff, idempotency keys, error envelope), Endpoints = docs/03,
                     RemoteCoachService.                                                     → CoreModels
  NutritionKit       NutritionCalculator, household units, MealDraft/DraftItem (Estimate vs Weighed),
                     LocalFoodCache, RemoteNutritionDatabase.                                 → CoreModels, Networking
  FoodScaleKit       FoodScaleDriver protocol, registry, 0x2A9D parser, stable-weight detector, drivers,
                     FoodScaleManager (CoreBluetooth).                                         (no deps)
  BodyScaleKit       HealthKitBodyScaleProvider, 0x2A9C parser, BLE body-scale skeleton.     → CoreModels, FoodScaleKit
  FoodRecognitionKit MealPhotoPipeline (presigned upload + analysis), ImagePreprocessor.     → CoreModels, Networking, NutritionKit
  SyncKit            ConflictResolver + Outbox (Foundation), SyncEngine, SwiftData LocalStore, ConnectivityMonitor,
                     BackgroundSync, LiveHealthRepository.                                   → CoreModels, Networking, AnalyticsKit
  AuthKit            CognitoAuthService (Hosted UI + PKCE + refresh), KeychainStore, WebAuthenticator. → CoreModels
  HealthKitModule    HealthKitService: reads, writes, observer queries + background delivery. → CoreModels
  OuraModule         OuraConnectionService (server-side OAuth via ASWebAuthenticationSession). → CoreModels, Networking, AuthKit
  NotificationsKit   Local reminders, categories, push registration.                         → CoreModels
  DesignSystem       Palette, typography, Card, MetricTile, rings, sparkline, badges.        → CoreModels
  MockData           DemoDataProvider (90 days) + demo implementations of every port.        → CoreModels, AnalyticsKit, NutritionKit
```

Feature screens talk only to the protocols in `CoreModels/Ports.swift` (`HealthRepository`, `HealthDataSource`,
`OuraService`, `BodyScaleProvider`, `NutritionDatabase`, `MealRecognitionService`, `AuthService`,
`CoachService`, `SyncService`) through `AppEnvironment`. `FoodScaleDriver` lives in FoodScaleKit.

Foundation-only code (CoreModels, AnalyticsKit, NutritionKit, FoodScaleKit parsing/drivers, SyncKit
merge/outbox/engine, Networking, MockData) builds and tests on Linux; Apple-framework code is wrapped in
`#if canImport(...)`.

## Tests

```bash
cd ios/Packages/HealthAppKit
swift test            # macOS or Linux — 61 tests: AnalyticsKit, NutritionKit, FoodScaleKit, CoreModels, SyncKit
```

App-level tests (`HealthAppTests`) run from Xcode (⌘U) and exercise demo-mode wiring.

## Adding a food-scale driver

Scales differ wildly (standard Weight Scale profile, vendor GATT services, proprietary frames). Each one is a
small value type implementing `FoodScaleDriver`; all Bluetooth I/O stays in `FoodScaleManager`.

1. **Capture the protocol.** Get it from the vendor, or sniff it: use *LightBlue* / *nRF Connect* to note the
   advertised name, service UUIDs and manufacturer data, then subscribe to notify characteristics and record
   frames while placing known weights (0 g, 100 g, 500 g, negative after tare, unit switches).
2. **Copy the template.** Duplicate `Sources/FoodScaleKit/Drivers/ExampleVendorScaleDriver.swift` as
   `<Vendor>ScaleDriver.swift` and change:
   * `id` (stable, persisted) and `displayName`;
   * `serviceUUIDs` / `notifyCharacteristicUUIDs` (16-bit like `"FFE0"` or full 128-bit strings);
   * `matchScore(for:)` — return `> 0` only for this scale (local-name prefix, company id from
     `advertisement.companyIdentifier`, advertised service). Vendor drivers should score higher (e.g. 50)
     than the generic standard driver (10);
   * `parse(characteristicUUID:value:receivedAt:)` — validate header/length/checksum, convert to **grams**,
     set `isStable` if the scale reports it (otherwise leave `false`; `StableWeightDetector` decides);
   * `tareCommand()` / `unitCommand(_:)` if the scale accepts writes (otherwise the manager tares in software).
3. **Test it.** Add captured frames to `Tests/FoodScaleKitTests` (see `testExampleVendorFrame`) — parsing is
   Foundation-only, so `swift test` runs on any machine.
4. **Register it** in `FoodScaleRegistry.standard` (`Parsing/FoodScaleDriver.swift`).
5. Try it on device: Settings → Devices → Scan for scales. The driver name is shown next to each discovered scale.

The standard driver handles any scale exposing the Bluetooth SIG Weight Scale service (0x181D) / Weight
Measurement (0x2A9D): flags bit 0 selects SI (0.005 kg) or imperial (0.01 lb) resolution; optional timestamp,
user id and BMI/height fields are parsed.

## Data, privacy & security

* SwiftData store in Application Support with `FileProtectionType.complete`; Cognito tokens in the Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
* Offline logging: every meal/note write goes to SwiftData **and** a `PendingChange` outbox row; `SyncEngine`
  pushes on connectivity, foreground and BGAppRefresh, resolves conflicts (meals: field-level LWW with
  items merged by id; others: server wins — docs/03 §3.4) and pulls the change feed.
* HealthKit-derived data is uploaded in idempotent batches (`/v1/metrics/daily`, `/v1/body`, `/v1/workouts`),
  filtered by the user's per-metric toggles.
* Meal photos are downscaled and re-encoded without EXIF/GPS before upload; the S3 PUT sends every header
  returned in `requiredHeaders`.
* Fueling messages are neutral by construction (`FuelingInsightEngine.forbiddenWords` is enforced by tests);
  the UI never frames a calorie deficit as an achievement.
