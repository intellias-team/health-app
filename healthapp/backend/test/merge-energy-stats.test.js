import { test } from "node:test";
import assert from "node:assert/strict";
import { mergeDailyMetrics, mergeDayItems, precedenceFor } from "../src/services/merge.js";
import { computeDailyEnergy, estimateRestingKcal, fuelingInsight } from "../src/services/energy.js";
import { acuteChronic, CORRELATION_CAVEAT, mean, pearson, rollingAverage, summarize, trainingLoad, weeklyAggregate } from "../src/services/stats.js";

// ── merge ───────────────────────────────────────────────────────────────────
test("merge: Oura wins for sleep/readiness/HRV/temperature, HealthKit for steps/energy", () => {
  const { merged, provenance } = mergeDailyMetrics({
    healthkit: { steps: 9000, activeKcal: 500, sleepMinutes: 400, hrvMs: 45, restingHr: 55, tempDeviationC: 0.1 },
    oura: { steps: 8700, activeKcal: 450, sleepMinutes: 420, hrvMs: 60, hrvMethod: "rmssd", readinessScore: 80, restingHr: 50, restingHrMethod: "sleepLowest", tempDeviationC: -0.2 },
  });
  assert.equal(merged.steps, 9000);
  assert.equal(merged.activeKcal, 500);
  assert.equal(merged.sleepMinutes, 420);
  assert.equal(merged.hrvMs, 60);
  assert.equal(merged.hrvMethod, "rmssd");
  assert.equal(merged.restingHrMethod, "sleepLowest");
  assert.equal(merged.tempDeviationC, -0.2);
  assert.equal(provenance.steps, "healthkit");
  assert.equal(provenance.readinessScore, "oura");
});

test("merge: manual entries override, falls back to whichever source has data", () => {
  const { merged, provenance } = mergeDailyMetrics({ healthkit: { sleepMinutes: 400, waterMl: 1000 }, manual: { waterMl: 1800 } });
  assert.equal(merged.waterMl, 1800);
  assert.equal(provenance.waterMl, "manual");
  assert.equal(merged.sleepMinutes, 400, "Oura missing → HealthKit used");
});

test("merge: user precedence preferences override defaults but manual stays first", () => {
  assert.deepEqual(precedenceFor("sleepMinutes", { sleepMinutes: ["healthkit"] }), ["manual", "healthkit", "oura"]);
  const { merged } = mergeDailyMetrics({ healthkit: { steps: 1 }, oura: { steps: 2 } }, { preferences: { "*": ["oura"] } });
  assert.equal(merged.steps, 2);
});

test("mergeDayItems groups by date and skips tombstones", () => {
  const days = mergeDayItems([
    { date: "2026-10-02", source: "oura", metrics: { sleepScore: 80 } },
    { date: "2026-10-01", source: "healthkit", metrics: { steps: 5 } },
    { date: "2026-10-01", source: "oura", metrics: { steps: 9 }, deleted: true },
  ]);
  assert.deepEqual(days.map((d) => d.date), ["2026-10-01", "2026-10-02"]);
  assert.equal(days[0].merged.steps, 5);
});

// ── energy ──────────────────────────────────────────────────────────────────
const PRAISE = /great job|well done|nice work|awesome|keep it up|congrat|amazing|good job|on track to lose|crushing/i;
const energy = (intake, total, extra = {}) => ({
  restingKcal: total - 600, restingSource: "measured", activeKcal: 600, totalKcal: total, intakeKcal: intake,
  balanceKcal: intake === null ? null : intake - total, mealsLogged: intake ? 2 : 0, complete: { intake: intake !== null, expenditure: true }, ...extra,
});

test("energy: resting from source, else Mifflin–St Jeor estimate; balance = intake − TDEE", () => {
  const e = computeDailyEnergy({ merged: { restingKcal: 1600, activeKcal: 500 }, meals: [{ totals: { kcal: 1800 } }, { totals: { kcal: 300 }, deleted: true }] });
  assert.deepEqual([e.totalKcal, e.intakeKcal, e.balanceKcal, e.restingSource], [2100, 1800, -300, "measured"]);
  assert.equal(estimateRestingKcal({ weightKg: 70, heightCm: 175, age: 30, sex: "male" }), 1649);
  const est = computeDailyEnergy({ merged: {}, meals: [], profile: { birthYear: 1996, heightCm: 175, sex: "male" }, weightKg: 70, year: 2026 });
  assert.equal(est.restingSource, "estimated");
  assert.equal(est.intakeKcal, null);
  assert.equal(est.complete.expenditure, false);
});

test("fueling insight: low intake after 6pm → neutral recovery message, never praise", () => {
  const insight = fuelingInsight({ today: energy(1000, 2600), localHour: 19, isToday: true });
  assert.equal(insight.type, "fueling");
  assert.match(insight.message, /38%/);
  assert.match(insight.message, /recovery|balanced meal|isn't logged/i);
  assert.doesNotMatch(`${insight.title} ${insight.message}`, PRAISE);
  assert.doesNotMatch(insight.message, /deficit/i, "no deficit framing in user-facing text");
});

test("fueling insight: before 6pm only on a high-load day", () => {
  assert.equal(fuelingInsight({ today: energy(1000, 2600), localHour: 14, isToday: true }), null);
  const hi = fuelingInsight({ today: energy(1000, 2600), localHour: 14, isToday: true, dayLoad: 200 });
  assert.equal(hi.type, "fueling");
  assert.match(hi.message, /Training load/);
  assert.doesNotMatch(hi.message, PRAISE);
});

test("fueling insight: 3-day average shortfall > 35 % triggers even when today is ok-ish", () => {
  const r = fuelingInsight({ today: energy(1700, 2600), previousDays: [energy(1400, 2600), energy(1500, 2600)], localHour: 20, isToday: true });
  assert.equal(r.type, "fueling");
  assert.match(r.message, /last 3 days/);
  assert.doesNotMatch(r.message, PRAISE);
  assert.equal(fuelingInsight({ today: energy(2400, 2600), previousDays: [energy(2300, 2600), energy(2500, 2600)], localHour: 20, isToday: true }), null);
});

test("fueling insight: incomplete data is called out", () => {
  const noExp = fuelingInsight({ today: energy(1000, 2600, { totalKcal: null }), localHour: 20, isToday: true });
  assert.equal(noExp.type, "data_incomplete");
  const noMeals = fuelingInsight({ today: energy(null, 2600), localHour: 21, isToday: true });
  assert.equal(noMeals.type, "data_incomplete");
  assert.match(noMeals.message, /No meals are logged/);
  assert.equal(fuelingInsight({ today: energy(null, 2600), localHour: 9, isToday: true }), null);
});

// ── stats ───────────────────────────────────────────────────────────────────
test("summary stats, rolling average and weekly aggregation", () => {
  const pts = [
    { date: "2026-09-28", value: 10 }, { date: "2026-09-29", value: null }, { date: "2026-09-30", value: 20 },
    { date: "2026-10-05", value: 30 }, { date: "2026-10-06", value: 50 },
  ];
  assert.deepEqual(summarize(pts), { avg: 27.5, min: 10, max: 50, delta: 40, n: 4 });
  assert.equal(mean([1, 2, null, 3]), 2);
  const weekly = weeklyAggregate(pts);
  assert.deepEqual(weekly, [{ date: "2026-09-28", value: 15 }, { date: "2026-10-05", value: 40 }]);
  assert.deepEqual(weeklyAggregate(pts, "sum")[1], { date: "2026-10-05", value: 80 });
  const roll = rollingAverage([{ date: "a", value: 1 }, { date: "b", value: 3 }, { date: "c", value: null }], 2);
  assert.deepEqual(roll.map((p) => p.value), [1, 2, 3]);
});

test("pearson r with n and a correlation-not-causation caveat", () => {
  const perfect = pearson([1, 2, 3, 4, 5].map((x) => ({ x, y: 2 * x + 1 })));
  assert.equal(perfect.r, 1);
  assert.equal(perfect.n, 5);
  assert.equal(perfect.caveat, CORRELATION_CAVEAT);
  assert.match(perfect.caveat, /not causation/i);
  const neg = pearson([{ x: 1, y: 3 }, { x: 2, y: 2 }, { x: 3, y: 1 }, { x: 4, y: null }]);
  assert.equal(neg.r, -1);
  assert.equal(neg.n, 3);
  assert.equal(pearson([{ x: 1, y: 1 }, { x: 2, y: 2 }]).r, null, "n < 3");
  assert.equal(pearson([{ x: 1, y: 1 }, { x: 1, y: 2 }, { x: 1, y: 3 }]).r, null, "zero variance");
});

test("training load (TRIMP) and acute:chronic ratio", () => {
  const easy = trainingLoad({ durationMin: 60, avgHr: 120 }, { restingHr: 60, maxHr: 190, sex: "male" });
  const hard = trainingLoad({ durationMin: 60, avgHr: 170 }, { restingHr: 60, maxHr: 190, sex: "male" });
  assert.ok(hard.load > easy.load * 2);
  assert.equal(easy.estimated, false);
  assert.equal(trainingLoad({ durationMin: 30 }).estimated, true);
  const loads = {};
  for (let i = 0; i < 28; i++) loads[new Date(Date.UTC(2026, 9, 3 - i)).toISOString().slice(0, 10)] = i < 7 ? 100 : 50;
  const acr = acuteChronic(loads, "2026-10-03");
  assert.equal(acr.acute7, 100);
  assert.equal(acr.chronic28, 62.5);
  assert.equal(acr.ratio, 1.6);
});
