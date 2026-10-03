/**
 * Small statistics toolkit for trends and the coach: summaries, rolling averages, weekly
 * aggregation, Pearson correlation (always with n and a caveat), and training load.
 */
import { addDays, isoWeekStart } from "../lib/dates.js";

export const CORRELATION_CAVEAT =
  "Correlation is not causation: these two measures moving together does not show that one causes the other. " +
  "Other factors (sleep, stress, illness, training, logging gaps) can drive both, and small samples are noisy.";

/** @typedef {{ date: string, value: number | null }} Point */

const nums = (values) => values.filter((x) => typeof x === "number" && Number.isFinite(x));
const round = (x, dp = 2) => (x === null || x === undefined ? null : Math.round(x * 10 ** dp) / 10 ** dp);

/** @param {number[]} values */
export function mean(values) {
  const xs = nums(values);
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}

/** Sample standard deviation. @param {number[]} values */
export function stdDev(values) {
  const xs = nums(values);
  if (xs.length < 2) return null;
  const m = mean(xs);
  return Math.sqrt(xs.reduce((s, x) => s + (x - m) ** 2, 0) / (xs.length - 1));
}

/**
 * avg / min / max / delta (last − first non-null value) of a point series.
 * @param {Point[]} points
 */
export function summarize(points) {
  const present = points.filter((p) => typeof p.value === "number");
  if (!present.length) return { avg: null, min: null, max: null, delta: null, n: 0 };
  const values = present.map((p) => p.value);
  return {
    avg: round(mean(values)),
    min: Math.min(...values),
    max: Math.max(...values),
    delta: present.length >= 2 ? round(present[present.length - 1].value - present[0].value) : null,
    n: present.length,
  };
}

/**
 * Trailing rolling average over `window` calendar points (needs at least half the window present).
 * @param {Point[]} points sorted by date, one per day
 * @param {number} window
 * @returns {Point[]}
 */
export function rollingAverage(points, window = 7) {
  const minCount = Math.ceil(window / 2);
  return points.map((p, i) => {
    const slice = points.slice(Math.max(0, i - window + 1), i + 1).map((x) => x.value);
    const present = nums(slice);
    return { date: p.date, value: present.length >= minCount ? round(mean(present)) : null };
  });
}

/**
 * Aggregate daily points into ISO weeks (Monday start).
 * @param {Point[]} points @param {"mean"|"sum"} [how]
 * @returns {Point[]} one point per week dated by its Monday
 */
export function weeklyAggregate(points, how = "mean") {
  const weeks = new Map();
  for (const p of points) {
    const wk = isoWeekStart(p.date);
    if (!weeks.has(wk)) weeks.set(wk, []);
    weeks.get(wk).push(p.value);
  }
  return [...weeks.entries()]
    .sort(([a], [b]) => (a < b ? -1 : 1))
    .map(([date, values]) => {
      const xs = nums(values);
      if (!xs.length) return { date, value: null };
      return { date, value: round(how === "sum" ? xs.reduce((a, b) => a + b, 0) : mean(xs)) };
    });
}

/**
 * Pearson correlation of paired observations. Returns `r: null` when n < 3 or a series is constant.
 * @param {{ x: number|null, y: number|null }[]} pairs
 * @returns {{ r: number|null, n: number, caveat: string }}
 */
export function pearson(pairs) {
  const ps = pairs.filter((p) => typeof p.x === "number" && typeof p.y === "number");
  const n = ps.length;
  if (n < 3) return { r: null, n, caveat: CORRELATION_CAVEAT };
  const mx = mean(ps.map((p) => p.x));
  const my = mean(ps.map((p) => p.y));
  let sxy = 0, sxx = 0, syy = 0;
  for (const { x, y } of ps) {
    sxy += (x - mx) * (y - my);
    sxx += (x - mx) ** 2;
    syy += (y - my) ** 2;
  }
  if (sxx === 0 || syy === 0) return { r: null, n, caveat: CORRELATION_CAVEAT };
  return { r: round(sxy / Math.sqrt(sxx * syy), 3), n, caveat: CORRELATION_CAVEAT };
}

/** Plain-language strength label for |r|. */
export function correlationStrength(r) {
  if (r === null) return "insufficient data";
  const a = Math.abs(r);
  if (a < 0.1) return "none";
  if (a < 0.3) return "weak";
  if (a < 0.5) return "moderate";
  return "strong";
}

/**
 * Session training load (Banister TRIMP): minutes × HR-reserve fraction × sex-specific weighting.
 * Without heart-rate data the session is scored at a moderate assumed intensity (HRr 0.5) and
 * flagged `estimated`.
 * @param {{ durationMin: number, avgHr?: number }} workout
 * @param {{ restingHr?: number, maxHr?: number, age?: number, sex?: string }} [athlete]
 * @returns {{ load: number, estimated: boolean }}
 */
export function trainingLoad(workout, athlete = {}) {
  const minutes = Math.max(0, workout.durationMin || 0);
  const rest = athlete.restingHr ?? 60;
  const max = athlete.maxHr ?? (athlete.age ? 208 - 0.7 * athlete.age : 190);
  const k = athlete.sex === "female" ? { a: 0.86, b: 1.67 } : athlete.sex === "male" ? { a: 0.64, b: 1.92 } : { a: 0.75, b: 1.8 };
  let hrr;
  let estimated = false;
  if (typeof workout.avgHr === "number" && max > rest) {
    hrr = Math.min(1, Math.max(0, (workout.avgHr - rest) / (max - rest)));
  } else {
    hrr = 0.5;
    estimated = true;
  }
  return { load: Math.round(minutes * hrr * k.a * Math.exp(k.b * hrr) * 10) / 10, estimated };
}

/**
 * Acute (7-day) vs chronic (28-day) mean daily load ending at `endDate`. Days without sessions
 * count as zero load.
 * @param {Record<string, number>} loadsByDate
 * @param {string} endDate
 */
export function acuteChronic(loadsByDate, endDate) {
  const sumOver = (days) => {
    let s = 0;
    for (let i = 0; i < days; i++) s += loadsByDate[addDays(endDate, -i)] ?? 0;
    return s / days;
  };
  const acute = sumOver(7);
  const chronic = sumOver(28);
  return { acute7: round(acute, 1), chronic28: round(chronic, 1), ratio: chronic > 0 ? round(acute / chronic) : null };
}
