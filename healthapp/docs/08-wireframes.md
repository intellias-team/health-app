# 8 · Wireframes & Visual Design

> Low-fidelity, screen-by-screen. Feature folders refer to `ios/HealthApp/Features/*` (doc 09).
> **Original identity**: HealthApp does not copy the layouts, ring styles, score dials, colour schemes or branding of Oura, WHOOP, Apple Health/Fitness or MyFitnessPal. Our signature element is the three-lane **Fuel · Train · Recover** card; scores from partners are shown as plain labelled numbers with source badges, never in their visual style.
>
> Notation: `[Button]`, `( toggle )`, `‹ back`, `▸ disclosure`, `◐` loading, `~` estimate, `⚖` weighed, `●` confidence.

## 8.0 Navigation

```
┌──────────────────────────────────────────┐
│                 (screen)                 │
├──────────────────────────────────────────┤
│  Today    Food    Trends    Coach   More │   More ▸ Activity, Recovery, Body,
└──────────────────────────────────────────┘          Calendar, Settings
```
Today cards deep-link to Activity / Recovery / Body. Date header on Today opens Calendar.

---

## 8.1 Onboarding

### 8.1.1 Welcome
```
┌──────────────────────────────────────────┐
│                                          │
│        ◯ HealthApp                       │
│                                          │
│   Fuel. Train. Recover.                  │
│   One honest picture of your day.        │
│                                          │
│   • Your data, your choice of sources    │
│   • Estimates always shown as estimates  │
│   • Private by default                   │
│                                          │
│   [        Get started        ]          │
│   Privacy policy · Terms                 │
└──────────────────────────────────────────┘
```
Purpose: set tone and promises. Components: wordmark, 3 promises, CTA. States: n/a. Interactions: Get started → Sign in.

### 8.1.2 Sign in with Apple
```
┌──────────────────────────────────────────┐
│ ‹                                        │
│   Create your account                    │
│   We only need an Apple ID. You can      │
│   hide your email.                       │
│                                          │
│   [   Sign in with Apple  ]   (system)   │
│                                          │
│   Try the demo instead ▸                 │
└──────────────────────────────────────────┘
```
Components: system `SignInWithAppleButton` style via Cognito Hosted UI (`ASWebAuthenticationSession`), demo link (DemoDataProvider). States: loading (◐ "Signing in…"), error ("Sign-in was cancelled" / "Couldn't reach server — try again"), offline (button disabled + "You're offline. Try the demo"). Interactions: success → Choose sources.

### 8.1.3 Choose sources (per-metric toggles)
```
┌──────────────────────────────────────────┐
│ ‹  Choose your sources          Step 2/4 │
│ ┌──────────────────────────────────────┐ │
│ │  Apple Health              [Connect] │ │
│ │  ( on) Steps        ( on) Workouts   │ │
│ │  ( on) Active energy( on) Weight     │ │
│ │  (off) Sleep        ( on) HRV        │ │
│ │  ▸ more metrics (8)                  │ │
│ └──────────────────────────────────────┘ │
│ ┌──────────────────────────────────────┐ │
│ │  Oura Ring                 [Connect] │ │
│ │  ( on) Sleep  ( on) Readiness        │ │
│ │  ( on) HRV    (off) Workouts         │ │
│ │  May require an Oura Membership.     │ │
│ └──────────────────────────────────────┘ │
│   Smart scale · Food scale — set up later│
│                                          │
│   [ Continue ]        Skip for now       │
└──────────────────────────────────────────┘
```
Purpose: explicit, granular consent (P5). Components: one card per provider, metric toggles mapping to `enabledMetrics[]`, per-provider Connect. States: connected (✓ + "Last sync 2 min ago"), error ("Oura connection failed — retry"), offline (Connect disabled for Oura; Apple Health still works). Interactions: Apple Health Connect → system HealthKit sheet with only toggled types; Oura Connect → web auth; then Goals step (optional calorie target, mode `maintain / gain / lose_gently / performance`), then Notifications permission.

---

## 8.2 Today

```
┌──────────────────────────────────────────┐
│  Fri 3 Oct ▾                      ⟳  ⚙  │
│ ┌──────────────────────────────────────┐ │
│ │  FUEL · TRAIN · RECOVER              │ │
│ │  ▮▮▮▮▮▮▱▱▱  Fuel     1,420 / ~2,450  │ │ amber
│ │  ▮▮▮▮▮▮▮▮▱  Train    Heavy · load 142│ │ coral
│ │  ▮▮▮▮▱▱▱▱▱  Recover  Readiness 64 ⓞ │ │ teal  (ⓞ = Oura source)
│ │  ───────────────────────────────────  │ │
│ │  Big training day and recovery is a   │ │
│ │  bit lower. A protein-and-carb dinner │ │
│ │  will help you recover.               │ │
│ └──────────────────────────────────────┘ │
│  DAILY ENERGY                    ⓘ       │
│   In   ~1,320–1,540 kcal (estimate)      │
│   Out  ~2,300–2,600 kcal (estimated)     │
│   ▮▮▮▮▮▮▮▮▱▱▱▱▱▱▱  Day in progress       │
│  MACROS                                  │
│   ◔ P 92/140g  ◑ C 160/300g  ◔ F 48/80g  │
│ ┌────────┐┌────────┐┌────────┐┌────────┐ │
│ │Sleep   ││HRV     ││RHR     ││Steps   │ │
│ │7h 12m  ││48 ms ⓞ ││54 bpm  ││8,214   │ │
│ │▁▃▅▆▅▇  ││▅▄▃▄▃▂  ││▃▃▄▃▃▃  ││▂▅▃▆▄▅  │ │
│ └────────┘└────────┘└────────┘└────────┘ │
│  WORKOUTS   Strength 62 min · 410 kcal ▸ │
│  WATER      ▮▮▮▮▱▱ 1.2 / 2.5 L  [+250ml] │
└──────────────────────────────────────────┘
```
Purpose: the daily answer (P1). Components: Fuel·Train·Recover card (AnalyticsKit `DailyBalance`), neutral fueling message (rules in doc 01 §1.10), Daily Energy with ranges, macro rings (`RingView`; three small separate rings in the fuel accent with gram labels — not concentric activity-style rings), metric tiles with sparkline and source badge, workouts, hydration quick-add. States: **empty** (no sources: "Connect a source or log a meal to see your day" + buttons); **loading** (skeleton tiles, cached values shown greyed with "Updating…"); **error** (tile shows "—" + "Couldn't load Oura data" link to Data Sources); **offline** (banner "Offline — showing saved data"; hydration and logging still work). Interactions: tap lane → Activity/Recovery/Food; tap tile → Trend detail; pull to refresh; date ▾ → Calendar; ⓘ explains estimate math.

---

## 8.3 Food

### 8.3.1 Food log
```
┌──────────────────────────────────────────┐
│  Food            ‹ Fri 3 Oct ›    [＋]   │
│  ~1,320–1,540 kcal · P 92 · C 160 · F 48 │
│  BREAKFAST                        420    │
│   Oats with blueberries   ⚖   350 kcal  │
│   Flat white                    70 kcal  │
│  LUNCH                   ~720–940  Est.  │
│   [img] Chicken rice bowl  ●●○ ~830     │
│  DINNER                                  │
│   + Add dinner                           │
│  SNACKS                                  │
│   + Add snack                            │
│  History ▸   Recipes ▸   Saved meals ▸   │
└──────────────────────────────────────────┘
```
Components: day switcher, totals with range, sections per `category`, meal rows (photo thumb, ⚖ weighed, ● confidence, Est. badge). States: empty day ("Nothing logged yet — add your first meal"), loading (skeleton rows), error (row-level "Not synced" icon with retry), offline (rows show ⇡ pending-sync dot). Interactions: ＋ / "Add …" → Add Food sheet (category preselected); tap meal → Meal editor; swipe → delete / duplicate / save as meal.

### 8.3.2 Add Food sheet
```
┌──────────────────────────────────────────┐
│  Add to Lunch                       ✕    │
│ ┌────────┐┌────────┐┌────────┐┌────────┐ │
│ │ Photo  ││ Scale  ││Barcode ││ Search │ │
│ └────────┘└────────┘└────────┘└────────┘ │
│ ┌────────┐┌────────┐┌────────┐┌────────┐ │
│ │ Voice  ││ Saved  ││Restaur.││ Custom │ │
│ └────────┘└────────┘└────────┘└────────┘ │
│  RECENT                                  │
│   Greek yogurt 170 g            [＋]    │
│   Banana, medium                [＋]    │
└──────────────────────────────────────────┘
```
Components: 8 entry methods, recents. States: Scale tile shows "Not paired" when no food scale; offline: Photo shows "Will analyse when online", Barcode/Search use local cache + custom foods only. Interactions: each tile → its flow; Restaurant → search restricted to restaurant items (if licensed DB) else "Describe it" voice/text with wide range.

### 8.3.3 Photo confirm
```
┌──────────────────────────────────────────┐
│ ‹  Confirm lunch                ESTIMATE │
│ [ photo thumbnail ]                      │
│  Total ~720–940 kcal  ·  P 48 C 92 F 21  │
│ ┌──────────────────────────────────────┐ │
│ │ White rice, cooked      ●●○ Medium   │ │
│ │ ~180 g  ├────●──────┤ 130–240 g      │ │
│ │ ~234 kcal (169–312)                  │ │
│ │ Also: jasmine rice · brown rice      │ │
│ ├──────────────────────────────────────┤ │
│ │ Chicken breast, grilled ⚖ 141 g      │ │
│ │ 232 kcal  ·  weighed                 │ │
│ ├──────────────────────────────────────┤ │
│ │ ⚠ Choose a food: "green sauce"  ▸    │ │
│ └──────────────────────────────────────┘ │
│  Was the chicken cooked with oil?        │
│  [ No oil ] [ A little ] [ Lots ]        │
│  + Add item                              │
│  [            Save meal             ]    │
└──────────────────────────────────────────┘
```
Purpose: user confirms/corrects AI output; never implies precision (doc 07 §7.9). Components: Estimate label, confidence badge (dots + text), gram slider bounded by range ×1.5, kcal range, alternative chips, unmatched-item warning, question chips (answers add/adjust items), add item. States: **loading** ("Identifying foods…" → "Matching nutrition data…" with photo shimmer); **error** ("Couldn't analyse this photo" → Retry / Log manually); **no_food/unclear** (message + retake); **offline** (photo queued, "We'll analyse when you're back online", option to log manually now). Interactions: slider drag updates kcal live (NutritionKit); tapping an alternative swaps foodRef; Save disabled while any item lacks a food.

### 8.3.4 Scale weighing
```
┌──────────────────────────────────────────┐
│ ‹  Weigh items           Scale ● Connected│
│                                          │
│              182.4 g                     │
│           ✓ Stable                       │
│                                          │
│   [ Tare ]          [ Add as… ▸ ]        │
│  ITEMS                                   │
│   1. Rice, cooked     182 g   238 kcal   │
│   2. ── weighing… ──                     │
│  Total 238 kcal  (weighed, exact)        │
│   [ Add next item ]   [ Done ]           │
│   📷 Add a photo for identification      │
└──────────────────────────────────────────┘
```
Components: large live grams (monospaced digits, unit per profile), stable indicator (icon + text + haptic), tare, item list, add next, optional photo for fusion. States: scanning ("Looking for your scale…"), not found (pair guide), disconnected ("Reconnecting… items kept"), unstable ("Hold still…"), overload, Bluetooth off. Interactions: Add as… → food picker (recents, search, barcode); Add next item → tare; Done → Meal editor prefilled.

### 8.3.5 Barcode
```
┌──────────────────────────────────────────┐
│ ✕          Scan barcode           ⚡     │
│ ┌──────────────────────────────────────┐ │
│ │        [ live camera ]               │ │
│ │       ┌───────────────┐              │ │
│ │       │ ▌▌▐▌▌▐▐▌▌▐▌  │              │ │
│ │       └───────────────┘              │ │
│ └──────────────────────────────────────┘ │
│  Type the number instead ▸               │
│ ── result ───────────────────────────────│
│  Oat drink · Brand  (Open Food Facts)    │
│  Serving [1 glass 250 ml ▾] ×[1]  120kcal│
│  [ Add ]                                 │
└──────────────────────────────────────────┘
```
States: camera permission denied (explain + Settings), not found ("Not in our database — scan the label or create a custom food"), offline (cached barcodes only). Attribution line shown for OFF data.

### 8.3.6 Search
```
┌──────────────────────────────────────────┐
│ ‹ [🔍 greek yogurt               ✕ ]     │
│  Filters: All · My foods · Generic       │
│   Yogurt, Greek, plain, nonfat   USDA ▸  │
│     59 kcal / 100 g                      │
│   Yogurt, Greek, whole milk      USDA ▸  │
│   My Greek yogurt bowl          Saved ▸  │
│  Can't find it? Create custom food ▸     │
└──────────────────────────────────────────┘
```
States: empty query (recents & frequent), loading (inline ◐, debounce 300 ms), no results (create custom), offline (local cache + custom foods, label "Offline results").

### 8.3.7 Voice
```
┌──────────────────────────────────────────┐
│ ✕               Say what you ate         │
│        ( ◉ )  listening…                 │
│  "two scrambled eggs, a slice of         │
│   sourdough toast with butter and a      │
│   flat white"                (editable)  │
│  [ Done ]                                │
│ ── parsed ───────────────────────────────│
│   Eggs, scrambled  ×2  ~100–130 g  ~190 │
│   Sourdough, 1 slice  ~45–60 g     ~130 │
│   Butter  ~5–10 g                  ~55  │
│   Flat white  ~240 ml              ~110 │
│  [ Review & save ]                       │
└──────────────────────────────────────────┘
```
States: mic/speech permission denied, on-device recognition unavailable (falls back to typing), parse error ("Try saying it differently"), offline (transcript kept, parse later).

### 8.3.8 Meal editor
```
┌──────────────────────────────────────────┐
│ ‹  Lunch · 12:41            [ Save ]     │
│  Category [Lunch ▾]  Time [12:41]        │
│  [photo]  Keep photo beyond 30 days ( )  │
│  Items                                   │
│   Rice, cooked   [ 180 ] g   234 kcal ▸  │
│   Chicken        [ 141 ] g ⚖ 232 kcal ▸  │
│   + Add item                             │
│  Totals  ~720–940 kcal  P48 C92 F21 Fib7 │
│  Notes [ Restaurant: …               ]   │
│  Save as meal ▸   Delete meal            │
└──────────────────────────────────────────┘
```
"Keep photo" sets the S3 `pinned` tag. States: conflict after sync ("Updated on another device — merged" toast), offline (saves locally, ⇡ pending).

### 8.3.9 Recipes & saved meals
```
┌──────────────────────────────────────────┐
│ ‹  Recipes          [Recipes|Saved] [＋] │
│   Chili con carne · 6 servings  ▸        │
│     410 kcal / serving                   │
│   Overnight oats · 1 serving    ▸        │
│ ── recipe editor ────────────────────────│
│   Ingredients (raw weights)              │
│   Total cooked weight [ 2,140 ] g ⚖      │
│   Servings [ 6 ]  → 357 g / serving      │
│   [ Log a portion by weight ▸ ]          │
└──────────────────────────────────────────┘
```
`kind: recipe` uses `totalCookedWeightG` so a weighed portion maps to a fraction of the pot. Empty: "Save meals you eat often to log them in one tap."

---

## 8.4 Activity
```
┌──────────────────────────────────────────┐
│  Activity                  Week ▾        │
│  Steps 8,214   Active 640 kcal (est.)    │
│  ▁▃▅▆▅▇▃  (7-day bars, goal line)        │
│  TRAINING LOAD  ░░▒▒▓▓▓  142 (high)      │
│   7-day load vs 28-day avg: +18 %        │
│  WORKOUTS                                │
│   Strength · 62 min · avg HR 128   ⌚ ▸  │
│   Run · 5.2 km · 31 min             ⓞ ▸  │
└──────────────────────────────────────────┘
```
States: empty ("No workouts this week"), sources missing (connect prompt), loading skeleton, offline cached.

## 8.5 Recovery
```
┌──────────────────────────────────────────┐
│  Recovery                       Today ▾  │
│  Readiness 64 ⓞ     Sleep score 78 ⓞ    │
│  SLEEP  7h 12m   (in bed 7h 55m)         │
│   ▇▇▅▅▃▃▅▇▇▅▃  Deep 1h05 REM 1h40       │
│   Light/Core 4h02  Awake 25m             │
│  HRV 48 ms (RMSSD · Oura)  ↓ vs 30-day   │
│  Resting HR 54 bpm   Temp +0.3 °C        │
│  SpO₂ 97 %   Resp. 14.8 /min             │
│  ⓘ These are device estimates.           │
└──────────────────────────────────────────┘
```
Stage bar is a horizontal timeline in teal shades (not a copy of partner hypnograms). HRV label always shows method. States: no sleep data last night ("No sleep recorded — was your ring/watch worn?"), loading, offline.

## 8.6 Body
```
┌──────────────────────────────────────────┐
│  Body                      30d ▾  [＋]   │
│  Weight 78.4 kg   7-day avg 78.6 (→)     │
│  ·  · ·· · ·  ── avg line                │
│  COMPOSITION (estimated by your scale)   │
│   Body fat 18.2 %   Lean mass 61.2 kg ⓗ │
│  MEASUREMENTS                            │
│   Today 07:02  78.4 kg  Eufy via Health  │
│   Thu 07:10    78.9 kg  Manual           │
└──────────────────────────────────────────┘
```
Daily points are muted dots; the emphasised element is the 7-day average (avoid daily-number fixation). Add measurement sheet: weight, body fat, date/time, "also save to Apple Health" toggle. Empty: "Connect a smart scale via Apple Health or add a measurement."

## 8.7 Trends

### 8.7.1 Trends home
```
┌──────────────────────────────────────────┐
│  Trends               7d · 30d · 90d · 1y│
│  FUEL     kcal in    ▁▃▅▃▅▆  avg ~2,180 ▸│
│           Protein    ▃▃▅▅▅▆  avg 128 g  ▸│
│  TRAIN    Load       ▂▅▃▆▄▅             ▸│
│  RECOVER  HRV        ▅▄▃▄▅▅  48 ms      ▸│
│           Sleep      ▅▅▆▄▅▆  7h05       ▸│
│  BODY     Weight     ▆▅▅▅▄▄  78.6 kg    ▸│
│  [ Compare two metrics ▸ ]               │
└──────────────────────────────────────────┘
```
### 8.7.2 Trend detail
```
┌──────────────────────────────────────────┐
│ ‹  HRV                  30d ▾  Day|Week  │
│   ┌──────────────────────────────────┐   │
│   │      ·   ·  ·                    │   │
│   │  ·  ·  ·  ·   ·  · ── 7d avg     │   │
│   └──────────────────────────────────┘   │
│  Avg 48  Min 36  Max 61   Δ −4 vs prior  │
│  Source: Oura (RMSSD)  ▸ change          │
│  Days with estimates are marked ◦        │
└──────────────────────────────────────────┘
```
### 8.7.3 Compare
```
┌──────────────────────────────────────────┐
│ ‹  Compare    X [Carbs g ▾] Y [HRV ▾]    │
│  Lag: [ same day | next day ]   90d ▾    │
│   ┌──────────────────────────────────┐   │
│   │ ·   ·  ·· ·   ·   ·  ·           │   │
│   │   · ·   ·  ·  ·  ·   ·  ·        │   │
│   └──────────────────────────────────┘   │
│  r = 0.24 (weak)  ·  n = 61 days         │
│  ⚠ Correlation isn't causation. Many     │
│  things affect both. Treat this as a     │
│  question to explore, not a conclusion.  │
└──────────────────────────────────────────┘
```
Caveat comes from API `caveat`; if n < 14 the chart shows "Not enough days yet" instead of r. States: loading, empty (missing metric data), offline (cached).

## 8.8 AI Coach
```
┌──────────────────────────────────────────┐
│  Coach                                   │
│  General wellness info, not medical      │
│  advice.                                 │
│  ┌ How did my sleep change this week? ┐  │
│  ┌ Am I eating enough on lifting days?┐  │
│  ── chat ────────────────────────────────│
│  You: Why is my HRV down?                │
│  Coach: Your HRV averaged 44 ms this     │
│  week vs 49 ms over the last 30 days.    │
│  It was lowest after your two late       │
│  workouts. That's an association, not a │
│  cause…   [HRV 26 Sep–2 Oct] [Workouts]  │
│  [ Ask something…              ] [Send]  │
└──────────────────────────────────────────┘
```
Citations are chips linking to Trend detail windows. States: empty (suggested questions), typing (◐ dots), error ("Coach is unavailable right now"), rate-limited ("You've reached the hourly limit — try again at 14:00"), offline (input disabled).

## 8.9 Calendar

### 8.9.1 Month
```
┌──────────────────────────────────────────┐
│  ‹ October 2026 ›                        │
│   M   T   W   T   F   S   S              │
│            1   2  [3]  4   5             │
│           ●●○ ●●● ●○○                    │
│   6   7   8   9  10  11  12              │
│  ● fuel logged  ● trained  ● recovered≥70│
└──────────────────────────────────────────┘
```
Dots use the three accents plus distinct shapes (● ▲ ■) for colour-blind accessibility.

### 8.9.2 Day detail
```
┌──────────────────────────────────────────┐
│ ‹  Friday 3 October                      │
│  Fuel ~1,980–2,240 · Train 142 · Rec 64  │
│  MEALS     Breakfast 420 · Lunch ~830 ▸  │
│  MACROS    P 128  C 240  F 70  Fib 31    │
│  WORKOUTS  Strength 62 min ▸             │
│  SLEEP     7h12 · score 78               │
│  WEIGHT    78.4 kg                       │
│  ACTIVITY  8,214 steps                   │
│  NOTE      [ Slept badly, travel day ]   │
└──────────────────────────────────────────┘
```
Backed by `GET /v1/day/{date}`; note editable (`PUT /v1/notes/{date}`).

## 8.10 Settings

### 8.10.1 Settings
```
┌──────────────────────────────────────────┐
│  Settings                                │
│   Data sources ▸        Devices ▸        │
│   Goals ▸               Notifications ▸  │
│   Units: Metric ▾       Cycle tracking ( )│
│   Account ▸             Privacy policy ▸ │
│   App version 1.0 (42)                   │
└──────────────────────────────────────────┘
```
### 8.10.2 Data Sources (permissions & precedence)
```
┌──────────────────────────────────────────┐
│ ‹  Data sources                          │
│  APPLE HEALTH  ✓ Last read 2 min ago     │
│   Steps ( on)  Energy ( on)  Sleep (off) │
│   Write nutrition to Health ( on)        │
│   Check Health permissions ▸             │
│  OURA  ⚠ Reconnect needed  [Reconnect]   │
│   Sleep ( on) Readiness ( on) HRV ( on)  │
│   Disconnect ▸                           │
│  PRIORITY (when both have data)          │
│   Sleep      [Oura ▾]                    │
│   Steps      [Apple Health ▾]            │
│   HRV        [Oura ▾]                    │
└──────────────────────────────────────────┘
```
Toggles → `PUT /v1/connections/{provider}`. States: error rows with reason (doc 05 §5.10), offline (toggles queued).

### 8.10.3 Devices
```
┌──────────────────────────────────────────┐
│ ‹  Devices                               │
│  FOOD SCALE                              │
│   Kitchen scale (Standard BLE) ● ▸ Forget│
│   [ Pair a food scale ]                  │
│  BODY SCALE                              │
│   Via Apple Health ✓ (any scale app)     │
│   [ Pair directly (coming soon) ]        │
│  MY PLATES   Blue bowl 412 g  [＋]       │
└──────────────────────────────────────────┘
```
Pairing sheet: scanning list with signal strength, "Supported scales" link, unsupported-device "Request support".

### 8.10.4 Notifications
```
┌──────────────────────────────────────────┐
│ ‹  Notifications                         │
│   Meal reminders        ( on) 8:00 13:00 │
│   Hydration nudges      (off)            │
│   Protein progress      ( on) 18:00      │
│   Sleep consistency     ( on)            │
│   Sync problems         ( on)            │
│   Quiet hours 22:00–07:00                │
└──────────────────────────────────────────┘
```
No notifications about weight changes or "you're over". Stored in `DEVICE#.notificationPrefs`.

### 8.10.5 Account (export / delete)
```
┌──────────────────────────────────────────┐
│ ‹  Account                               │
│   Signed in with Apple (private relay)   │
│   [ Export my data ]                     │
│     ZIP of all your data, link valid 15m │
│   [ Sign out ]                           │
│   [ Delete account ]  (destructive)      │
│ ── confirm sheet ────────────────────────│
│   This permanently deletes your meals,   │
│   metrics, photos and connections and    │
│   disconnects Oura. Apple Health data on │
│   this iPhone is not affected.           │
│   Type DELETE to confirm [        ]      │
│   [ Delete permanently ]                 │
└──────────────────────────────────────────┘
```
States: export in progress (◐ "Preparing…" → share sheet), delete in progress, offline (both disabled with reason).

---

## 8.11 Visual design system (`DesignSystem` package)

### Palette (semantic tokens; light / dark)
| Token | Light | Dark | Use |
|---|---|---|---|
| `fuel` (amber) | `#C77700` | `#FFB547` | intake, food, macros |
| `train` (coral) | `#D9483B` | `#FF7A6B` | activity, workouts, load |
| `recover` (teal) | `#0F8A80` | `#43D1C3` | sleep, HRV, readiness |
| `body` (indigo) | `#4B4FC9` | `#8F92FF` | weight, composition |
| `surface` / `surface2` | `#FFFFFF` / `#F4F3EF` | `#0F1113` / `#1A1D20` | backgrounds, cards |
| `ink` / `inkMuted` | `#15171A` / `#5E636B` | `#F2F3F5` / `#A2A8B0` | text |
| `estimate` | `#7A6F5A` | `#C9BDA6` | Estimate badges, range bands (hatched) |
| `warning` | `#B25E00` | `#FFB04D` | sync problems only |

Accent text on surfaces meets ≥ 4.5:1 (body) / 3:1 (large, graphics) — validate each token pair in CI snapshot tests. No red/green "good/bad" encoding for food.

### Type scale (SF Pro, Dynamic Type mapped)
| Style | Size/weight (default) | Text style |
|---|---|---|
| Display number | 34 / semibold, monospaced digits | `.largeTitle` |
| Title | 22 / semibold | `.title2` |
| Headline | 17 / semibold | `.headline` |
| Body | 17 / regular | `.body` |
| Caption (labels, sources) | 12 / medium, +2 % tracking, uppercase section labels | `.caption` |

### Card spec
Corner radius 20 (continuous), padding 16, 12 pt inter-card spacing, `surface2` fill, no drop shadows in dark mode (1 px hairline `ink` 8 %), 4 pt accent lane marker on the leading edge for semantic cards. Minimum tap target 44×44.

### Charts (Swift Charts)
Thin 2 pt lines, rounded caps; daily points as 4 pt muted dots with emphasised 7-day average line; **ranges as translucent hatched bands** in `estimate`; no 3D, no gradients-as-data; axis labels caption style; every chart has `accessibilityChartDescriptor` and an Audio Graph.

### Motion
120–250 ms ease-out; numbers count up only on first appearance per day; stable-weight confirmation = scale icon pulse + `.success` haptic; respect Reduce Motion (cross-fade only) and never animate warnings.

### Accessibility
Dynamic Type to AX5 (tiles reflow to single column); VoiceOver reads ranges as "between 720 and 940 kilocalories, estimate"; colour never the only signal (icons, shapes, text); Bold Text and Increase Contrast tokens; Voice Control labels on all buttons; haptics optional.
