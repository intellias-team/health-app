/**
 * Trend series for every metric id in the API contract (GET /v1/trends/{metric}) and pairwise
 * comparisons (GET /v1/trends/compare).
 */
import { ApiError } from "../lib/http.js";
import { addDays, dateRange, daysBetween, localDate } from "../lib/dates.js";
import { pearson, summarize, trainingLoad, weeklyAggregate } from "./stats.js";
import { precedenceFor } from "./merge.js";

/** Metrics whose meaning differs by source; trends never mix sources for these. */
export const SINGLE_SOURCE_METRICS = new Set(["hrvMs", "restingHr"]);

/**
 * Metric catalogue. `kind` selects the data source; `weekly` the weekly aggregation.
 * @type {Record<string, { unit: string, kind: "body"|"meals"|"daily"|"workouts"|"cycle", field?: string, weekly: "mean"|"sum" }>}
 */
export const TREND_METRICS = Object.freeze({
  weight: { unit: "kg", kind: "body", field: "weightKg", weekly: "mean" },
  bodyFatPct: { unit: "%", kind: "body", field: "bodyFatPct", weekly: "mean" },
  muscleMassKg: { unit: "kg", kind: "body", field: "muscleMassKg", weekly: "mean" },
  kcalIn: { unit: "kcal", kind: "meals", field: "kcal", weekly: "mean" },
  proteinG: { unit: "g", kind: "meals", field: "proteinG", weekly: "mean" },
  carbsG: { unit: "g", kind: "meals", field: "carbsG", weekly: "mean" },
  fatG: { unit: "g", kind: "meals", field: "fatG", weekly: "mean" },
  fiberG: { unit: "g", kind: "meals", field: "fiberG", weekly: "mean" },
  sleepScore: { unit: "score", kind: "daily", field: "sleepScore", weekly: "mean" },
  sleepMinutes: { unit: "min", kind: "daily", field: "sleepMinutes", weekly: "mean" },
  hrvMs: { unit: "ms", kind: "daily", field: "hrvMs", weekly: "mean" },
  restingHr: { unit: "bpm", kind: "daily", field: "restingHr", weekly: "mean" },
  readinessScore: { unit: "score", kind: "daily", field: "readinessScore", weekly: "mean" },
  activityScore: { unit: "score", kind: "daily", field: "activityScore", weekly: "mean" },
  steps: { unit: "count", kind: "daily", field: "steps", weekly: "mean" },
  activeKcal: { unit: "kcal", kind: "daily", field: "activeKcal", weekly: "mean" },
  workoutMinutes: { unit: "min", kind: "workouts", field: "durationMin", weekly: "sum" },
  trainingLoad: { unit: "TRIMP", kind: "workouts", field: "load", weekly: "sum" },
  cycleDay: { unit: "day", kind: "cycle", weekly: "mean" },
});

export const RANGES = Object.freeze({ "7d": 7, "30d": 30, "90d": 90, "1y": 365 });

/** @param {string} metric */
export function assertMetric(metric) {
  if (!TREND_METRICS[metric]) {
    throw new ApiError("VALIDATION_ERROR", `Unknown metric '${metric}'`, { details: { allowed: Object.keys(TREND_METRICS) } });
  }
  return TREND_METRICS[metric];
}

/** @param {string} range */
export function rangeDays(range = "30d") {
  const days = RANGES[range];
  if (!days) throw new ApiError("VALIDATION_ERROR", "range must be one of 7d, 30d, 90d, 1y");
  return days;
}

const PERIOD_FLOWS = new Set(["light", "medium", "heavy"]);

/**
 * Cycle day for each date: days since the most recent period start (day 1 = first flow day).
 * @param {{ date: string, flow?: string, phase?: string }[]} entries
 * @param {string[]} dates
 */
export function cycleDays(entries, dates) {
  const flowDays = new Set(entries.filter((e) => PERIOD_FLOWS.has(e.flow) || e.phase === "menstrual").map((e) => e.date));
  const starts = [...flowDays].filter((d) => !flowDays.has(addDays(d, -1))).sort();
  return dates.map((date) => {
    let start = null;
    for (const s of starts) if (s <= date) start = s;
    if (!start) return { date, value: null };
    const day = daysBetween(start, date) + 1;
    return { date, value: day <= 60 ? day : null };
  });
}

/**
 * Daily series for one metric over [from, to].
 * @param {import("./userData.js").UserData} data
 * @param {string} metric
 * @param {string} from @param {string} to
 * @param {{ profile?: any }} [ctx]
 * @returns {Promise<{ date: string, value: number|null }[]>}
 */
export async function dailySeries(data, metric, from, to, ctx = {}) {
  const def = assertMetric(metric);
  const profile = ctx.profile ?? (await data.profile());
  const tz = profile.timezone ?? "UTC";
  const dates = dateRange(from, to);
  const byDate = new Map(dates.map((d) => [d, null]));

  switch (def.kind) {
    case "daily": {
      const days = await data.daily(from, to, profile.sourcePrecedence);
      // HRV (SDNN vs RMSSD) and resting HR (Apple resting vs Oura sleep-lowest) are different
      // measures per source: a trend uses ONE source for the whole window, never a mix.
      const single = SINGLE_SOURCE_METRICS.has(def.field)
        ? precedenceFor(def.field, profile.sourcePrecedence).find((src) => days.some((d) => typeof d.bySource[src]?.[def.field] === "number"))
        : undefined;
      for (const day of days) {
        const v = single ? day.bySource[single]?.[def.field] : day.merged[def.field];
        if (typeof v === "number" && byDate.has(day.date)) byDate.set(day.date, v);
      }
      break;
    }
    case "meals": {
      for (const meal of await data.meals(from, to)) {
        const v = meal.totals?.[def.field];
        if (typeof v !== "number" || !byDate.has(meal.date)) continue;
        byDate.set(meal.date, Math.round(((byDate.get(meal.date) ?? 0) + v) * 10) / 10);
      }
      break;
    }
    case "body": {
      // last measurement of each local day
      const rows = (await data.body(from, to)).sort((a, b) => (a.measuredAt < b.measuredAt ? -1 : 1));
      for (const m of rows) {
        const d = localDate(m.measuredAt, tz);
        if (byDate.has(d) && typeof m[def.field] === "number") byDate.set(d, m[def.field]);
      }
      break;
    }
    case "workouts": {
      for (const d of dates) byDate.set(d, 0);
      const daily = metric === "trainingLoad" ? await data.daily(addDays(from, -1), to, profile.sourcePrecedence) : [];
      const restingByDate = new Map(daily.map((x) => [x.date, x.merged.restingHr]));
      const age = profile.birthYear ? new Date(`${to}T00:00:00Z`).getUTCFullYear() - profile.birthYear : undefined;
      for (const w of await data.workouts(from, to)) {
        const d = localDate(w.start, tz);
        if (!byDate.has(d)) continue;
        const value = metric === "workoutMinutes"
          ? w.durationMin ?? 0
          : typeof w.load === "number" ? w.load : trainingLoad(w, { restingHr: restingByDate.get(d), age, sex: profile.sex }).load;
        byDate.set(d, Math.round((byDate.get(d) + value) * 10) / 10);
      }
      break;
    }
    case "cycle": {
      if (!profile.cycleTrackingEnabled) break;
      const entries = await data.cycle(addDays(from, -60), to);
      for (const p of cycleDays(entries, dates)) byDate.set(p.date, p.value);
      break;
    }
  }
  return dates.map((date) => ({ date, value: byDate.get(date) }));
}

/**
 * @param {{ data: import("./userData.js").UserData, metric: string, range?: string, agg?: "day"|"week", today: string, profile?: any }} p
 */
export async function computeTrend({ data, metric, range = "30d", agg = "day", today, profile }) {
  const def = assertMetric(metric);
  const days = rangeDays(range);
  if (agg !== "day" && agg !== "week") throw new ApiError("VALIDATION_ERROR", "agg must be day or week");
  const from = addDays(today, -(days - 1));
  const daily = await dailySeries(data, metric, from, today, { profile });
  const points = agg === "week" ? weeklyAggregate(daily, def.weekly) : daily;
  const { avg, min, max, delta } = summarize(points);
  return { metric, unit: def.unit, range, agg, from, to: today, points, avg, min, max, delta };
}

/**
 * Pair two metrics by date (y optionally lagged by `lagDays`: x on day d vs y on day d+lag).
 * @param {{ data: import("./userData.js").UserData, x: string, y: string, range?: string, lagDays?: number, today: string, profile?: any }} p
 */
export async function computeCompare({ data, x, y, range = "30d", lagDays = 0, today, profile }) {
  assertMetric(x);
  assertMetric(y);
  if (![0, 1].includes(lagDays)) throw new ApiError("VALIDATION_ERROR", "lagDays must be 0 or 1");
  const days = rangeDays(range);
  const from = addDays(today, -(days - 1));
  const prof = profile ?? (await data.profile());
  const xs = await dailySeries(data, x, from, addDays(today, -lagDays), { profile: prof });
  const ys = await dailySeries(data, y, addDays(from, lagDays), today, { profile: prof });
  const yByDate = new Map(ys.map((p) => [p.date, p.value]));
  const pairs = xs
    .map((p) => ({ date: p.date, x: p.value, y: yByDate.get(addDays(p.date, lagDays)) ?? null }))
    .filter((p) => p.x !== null && p.y !== null);
  const { r, n, caveat } = pearson(pairs);
  return { x, y, range, lagDays, pairs, pearsonR: r, n, caveat };
}
