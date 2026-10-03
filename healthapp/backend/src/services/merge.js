/**
 * Source-precedence merge of daily metrics (schema §2.2.3):
 *   user override ("manual" source and per-metric preferences) → Oura for sleep / readiness / HRV /
 *   temperature → HealthKit for steps / energy / workouts / body.
 */

const OURA_FIRST = ["manual", "oura", "healthkit"];
const HEALTHKIT_FIRST = ["manual", "healthkit", "oura"];

/** Default precedence per metric key. */
export const DEFAULT_PRECEDENCE = Object.freeze({
  sleepMinutes: OURA_FIRST,
  sleepStages: OURA_FIRST,
  sleepScore: OURA_FIRST,
  readinessScore: OURA_FIRST,
  hrvMs: OURA_FIRST,
  tempDeviationC: OURA_FIRST,
  restingHr: OURA_FIRST,
  respiratoryRate: OURA_FIRST,
  spo2Pct: OURA_FIRST,
  bedtimeStart: OURA_FIRST,
  activityScore: OURA_FIRST,
  steps: HEALTHKIT_FIRST,
  activeKcal: HEALTHKIT_FIRST,
  restingKcal: HEALTHKIT_FIRST,
  waterMl: HEALTHKIT_FIRST,
  vo2max: HEALTHKIT_FIRST,
});

const FALLBACK = HEALTHKIT_FIRST;

/**
 * Resolve the precedence list for a metric. User preferences (`profile.sourcePrecedence`) may
 * contain per-metric lists or a `"*"` global list; "manual" always stays first because a manual
 * entry is an explicit user override.
 * @param {string} metric
 * @param {Record<string, string[]>} [preferences]
 */
export function precedenceFor(metric, preferences = {}) {
  const preferred = preferences[metric] ?? preferences["*"];
  const base = DEFAULT_PRECEDENCE[metric] ?? FALLBACK;
  if (!preferred?.length) return base;
  const ordered = ["manual", ...preferred.filter((s) => s !== "manual")];
  for (const s of base) if (!ordered.includes(s)) ordered.push(s);
  return ordered;
}

/**
 * Merge per-source metric maps for one day.
 * @param {Record<string, Record<string, any>>} bySource  e.g. `{ healthkit: {...}, oura: {...} }`
 * @param {{ preferences?: Record<string, string[]> }} [opts]
 * @returns {{ merged: Record<string, any>, provenance: Record<string, string> }}
 */
export function mergeDailyMetrics(bySource, opts = {}) {
  const merged = {};
  const provenance = {};
  const keys = new Set();
  for (const metrics of Object.values(bySource)) for (const k of Object.keys(metrics ?? {})) keys.add(k);
  keys.delete("hrvMethod");
  keys.delete("restingHrMethod");

  for (const key of keys) {
    const order = precedenceFor(key, opts.preferences);
    const sources = [...order, ...Object.keys(bySource).filter((s) => !order.includes(s))];
    for (const source of sources) {
      const value = bySource[source]?.[key];
      if (value === undefined || value === null) continue;
      merged[key] = value;
      provenance[key] = source;
      break;
    }
  }
  if (merged.hrvMs !== undefined) {
    const src = provenance.hrvMs;
    merged.hrvMethod = bySource[src]?.hrvMethod ?? (src === "oura" ? "rmssd" : "sdnn");
  }
  if (merged.restingHr !== undefined) {
    const src = provenance.restingHr;
    merged.restingHrMethod = bySource[src]?.restingHrMethod ?? (src === "oura" ? "sleepLowest" : "restingHeartRate");
  }
  return { merged, provenance };
}

/**
 * Group DAY# items into `{ date, merged, bySource, provenance }` sorted by date.
 * @param {any[]} dayItems repository items with `date`, `source`, `metrics`
 * @param {Record<string, string[]>} [preferences]
 */
export function mergeDayItems(dayItems, preferences) {
  const byDate = new Map();
  for (const item of dayItems) {
    if (item.deleted) continue;
    const entry = byDate.get(item.date) ?? {};
    entry[item.source] = item.metrics ?? {};
    byDate.set(item.date, entry);
  }
  return [...byDate.entries()]
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .map(([date, bySource]) => ({ date, ...mergeDailyMetrics(bySource, { preferences }), bySource }));
}
