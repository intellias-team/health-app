/**
 * Entity validators shared by the REST handlers and sync push (schema doc §2.2.1–2.2.3).
 */
import { v } from "./validate.js";

export const NUTRIENT_KEYS = /** @type {const} */ (["kcal", "proteinG", "carbsG", "fatG", "fiberG", "sugarG", "sodiumMg"]);
export const MEAL_CATEGORIES = ["breakfast", "lunch", "dinner", "snack", "drink"];
export const MEAL_SOURCES = ["photo", "scale", "barcode", "search", "voice", "recipe", "restaurant", "custom", "manual"];
export const WEIGHT_SOURCES = ["scale", "estimated", "user", "label"];
export const FOOD_DBS = ["usda", "off", "custom", "recipe", "ai"];
export const METRIC_SOURCES = ["healthkit", "oura", "manual"];
export const GOAL_MODES = ["maintain", "gain", "lose_gently", "performance"];

/** Daily metric keys (§2.2.3) plus additive `bedtimeStart`/`hrvMethod`. */
export const DAILY_METRIC_KEYS = [
  "steps", "activeKcal", "restingKcal", "restingHr", "hrvMs", "sleepMinutes", "sleepStages", "sleepScore",
  "readinessScore", "activityScore", "tempDeviationC", "respiratoryRate", "spo2Pct", "waterMl", "vo2max",
  "hrvMethod", "restingHrMethod", "bedtimeStart",
];

const num = (max = 1e7) => v.optional(v.number({ min: 0, max }));

export const nutrientsSchema = v.object(Object.fromEntries(NUTRIENT_KEYS.map((k) => [k, num(1e6)])));

export const foodRefSchema = v.object({ db: v.string({ enum: FOOD_DBS }), id: v.optional(v.string({ max: 100 })) });

export const foodItemSchema = v.object({
  id: v.id(),
  name: v.string({ min: 1, max: 200 }),
  foodRef: v.optional(foodRefSchema),
  grams: v.number({ min: 0, max: 10_000 }),
  gramsLow: num(10_000),
  gramsHigh: num(10_000),
  weightSource: v.default(v.string({ enum: WEIGHT_SOURCES }), "user"),
  confidence: v.optional(v.number({ min: 0, max: 1 })),
  nutrients: v.default(nutrientsSchema, {}),
  range: v.optional(v.object({ kcalLow: num(), kcalHigh: num() })),
});

export const mealSchema = v.object({
  id: v.uuid(),
  date: v.date(),
  loggedAt: v.timestamp(),
  category: v.string({ enum: MEAL_CATEGORIES }),
  source: v.default(v.string({ enum: MEAL_SOURCES }), "manual"),
  photoKey: v.optional(v.string({ max: 300 })),
  photoPinned: v.optional(v.boolean()),
  items: v.array(foodItemSchema, { max: 60 }),
  isEstimate: v.optional(v.boolean()),
  notes: v.optional(v.string({ max: 2000 })),
  analysisId: v.optional(v.id()),
});

export const profileSchema = v.object({
  displayName: v.optional(v.string({ max: 80 })),
  birthYear: v.optional(v.number({ int: true, min: 1900, max: 2100 })),
  sex: v.optional(v.string({ enum: ["female", "male", "other", "unspecified"] })),
  heightCm: v.optional(v.number({ min: 50, max: 260 })),
  units: v.optional(v.string({ enum: ["metric", "imperial"] })),
  timezone: v.optional(v.string({ max: 64, pattern: /^[A-Za-z0-9_+\-/]+$/ })),
  cycleTrackingEnabled: v.optional(v.boolean()),
  sourcePrecedence: v.optional(v.record(v.array(v.string({ enum: METRIC_SOURCES }), { max: 3 }), { keys: [...DAILY_METRIC_KEYS, "*"] })),
});

export const goalsSchema = v.object({
  calorieTarget: v.optional(v.number({ min: 0, max: 10_000 })),
  proteinG: num(1000),
  carbsG: num(2000),
  fatG: num(1000),
  fiberG: num(500),
  waterMl: num(20_000),
  stepGoal: num(200_000),
  sleepHours: v.optional(v.number({ min: 0, max: 24 })),
  mode: v.default(v.string({ enum: GOAL_MODES }), "maintain"),
});

/** Sleep stage minutes (schema §2.2.3). Oura `light` maps to `coreMin`. */
export const SLEEP_STAGE_KEYS = ["coreMin", "deepMin", "remMin", "awakeMin", "unspecifiedMin", "inBedMin", "napMin"];
export const sleepStagesSchema = v.object(Object.fromEntries(SLEEP_STAGE_KEYS.map((k) => [k, num(1440)])));

export const dailyMetricsMapSchema = v.object({
  steps: num(500_000),
  activeKcal: num(20_000),
  restingKcal: num(10_000),
  restingHr: num(300),
  restingHrMethod: v.optional(v.string({ enum: ["restingHeartRate", "sleepLowest"] })),
  hrvMs: num(1000),
  hrvMethod: v.optional(v.string({ enum: ["sdnn", "rmssd"] })),
  sleepMinutes: num(1440),
  sleepStages: v.optional(sleepStagesSchema),
  sleepScore: num(100),
  readinessScore: num(100),
  activityScore: num(100),
  tempDeviationC: v.optional(v.number({ min: -10, max: 10 })),
  respiratoryRate: num(100),
  spo2Pct: num(100),
  waterMl: num(20_000),
  vo2max: num(100),
  bedtimeStart: v.optional(v.timestamp()),
});

export const dailyMetricsSchema = v.object({
  date: v.date(),
  source: v.string({ enum: METRIC_SOURCES }),
  metrics: dailyMetricsMapSchema,
});

export const bodySchema = v.object({
  id: v.id(),
  measuredAt: v.timestamp(),
  source: v.string({ max: 64, pattern: /^[a-z0-9:_-]+$/i }),
  weightKg: num(700),
  bodyFatPct: num(100),
  leanMassKg: num(500),
  muscleMassKg: num(500),
  bmi: num(200),
  visceralFat: num(100),
  waterPct: num(100),
  boneMassKg: num(50),
  bmrKcal: num(10_000),
});

export const workoutSchema = v.object({
  id: v.id(),
  start: v.timestamp(),
  end: v.timestamp(),
  type: v.string({ max: 64 }),
  source: v.string({ max: 64, pattern: /^[a-z0-9:_-]+$/i }),
  durationMin: v.number({ min: 0, max: 2880 }),
  activeKcal: num(20_000),
  avgHr: num(260),
  maxHr: num(260),
  distanceM: num(1e6),
  externalId: v.optional(v.string({ max: 128 })),
});

export const customFoodSchema = v.object({
  name: v.string({ min: 1, max: 200 }),
  brand: v.optional(v.string({ max: 200 })),
  servingG: v.default(v.number({ min: 0, max: 10_000 }), 100),
  nutrientsPer100g: nutrientsSchema,
});

export const recipeSchema = v.object({
  name: v.string({ min: 1, max: 200 }),
  kind: v.default(v.string({ enum: ["recipe", "savedMeal"] }), "recipe"),
  items: v.array(foodItemSchema, { max: 100 }),
  totalCookedWeightG: num(100_000),
  servings: v.default(v.number({ min: 0.1, max: 1000 }), 1),
});

export const noteSchema = v.object({
  text: v.default(v.string({ max: 5000 }), ""),
  tags: v.default(v.array(v.string({ max: 40 }), { max: 20 }), []),
});

export const cycleSchema = v.object({
  flow: v.optional(v.string({ enum: ["none", "spotting", "light", "medium", "heavy"] })),
  phase: v.optional(v.string({ enum: ["menstrual", "follicular", "ovulation", "luteal"] })),
  symptoms: v.default(v.array(v.string({ max: 40 }), { max: 30 }), []),
});
