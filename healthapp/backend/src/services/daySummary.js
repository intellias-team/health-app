/**
 * GET /v1/day/{date} — DaySummary: meals, macro totals vs goals, workouts, merged metrics, body,
 * note, cycle (if opted in), energy balance and insights.
 */
import { addDays, localDate, localParts } from "../lib/dates.js";
import { NUTRIENT_KEYS, sumNutrients } from "./nutrition.js";
import { computeDailyEnergy, fuelingInsight } from "./energy.js";
import { acuteChronic, trainingLoad } from "./stats.js";

/**
 * @param {{ data: import("./userData.js").UserData, date: string, now: number }} p
 */
export async function buildDaySummary({ data, date, now }) {
  const profile = await data.profile();
  const tz = profile.timezone ?? "UTC";
  const local = localParts(now, tz);
  const isToday = local.date === date;
  const windowFrom = addDays(date, -27);

  const [goals, meals3, daily, bodyAll, workoutsAll, notes, cycle] = await Promise.all([
    data.goals(),
    data.meals(addDays(date, -2), date),
    data.daily(windowFrom, date, profile.sourcePrecedence),
    data.body(addDays(date, -30), date),
    data.workouts(windowFrom, date),
    data.notes(date, date),
    profile.cycleTrackingEnabled ? data.cycle(date, date) : Promise.resolve([]),
  ]);

  const meals = meals3.filter((m) => m.date === date).sort((a, b) => (a.loggedAt < b.loggedAt ? -1 : 1));
  const totals = sumNutrients(meals.map((m) => m.totals ?? {}));
  const totalsRange = meals.reduce(
    (acc, m) => ({ kcalLow: acc.kcalLow + (m.totalsRange?.kcalLow ?? m.totals?.kcal ?? 0), kcalHigh: acc.kcalHigh + (m.totalsRange?.kcalHigh ?? m.totals?.kcal ?? 0) }),
    { kcalLow: 0, kcalHigh: 0 },
  );

  const dayMetrics = daily.find((d) => d.date === date) ?? { merged: {}, bySource: {}, provenance: {} };
  const workouts = workoutsAll.filter((w) => localDate(w.start, tz) === date);

  const bodySorted = bodyAll.filter((b) => localDate(b.measuredAt, tz) <= date).sort((a, b) => (a.measuredAt < b.measuredAt ? -1 : 1));
  const bodyToday = bodySorted.filter((b) => localDate(b.measuredAt, tz) === date);
  const latestWeight = [...bodySorted].reverse().find((b) => typeof b.weightKg === "number")?.weightKg;

  // Training load for the day and the acute:chronic ratio
  const year = new Date(now).getUTCFullYear();
  const age = profile.birthYear ? year - profile.birthYear : undefined;
  const restingByDate = new Map(daily.map((d) => [d.date, d.merged.restingHr]));
  const loads = {};
  for (const w of workoutsAll) {
    const d = localDate(w.start, tz);
    const load = typeof w.load === "number" ? w.load : trainingLoad(w, { restingHr: restingByDate.get(d), age, sex: profile.sex }).load;
    loads[d] = (loads[d] ?? 0) + load;
  }
  const load = acuteChronic(loads, date);

  // Energy for the day and the two days before (for the 3-day fueling check)
  const energyFor = (d) => computeDailyEnergy({
    merged: daily.find((x) => x.date === d)?.merged ?? {},
    meals: meals3.filter((m) => m.date === d),
    profile,
    weightKg: latestWeight,
    year,
  });
  const energy = energyFor(date);
  const previous = [energyFor(addDays(date, -2)), energyFor(addDays(date, -1))];

  const insights = [];
  const fuel = fuelingInsight({
    today: energy,
    previousDays: previous,
    localHour: isToday ? local.hour : 23,
    isToday,
    dayLoad: loads[date] ?? 0,
    acwr: load.ratio,
  });
  if (fuel) insights.push(fuel);

  const progress = {};
  const goalMap = { kcal: goals.calorieTarget, proteinG: goals.proteinG, carbsG: goals.carbsG, fatG: goals.fatG, fiberG: goals.fiberG };
  for (const k of NUTRIENT_KEYS) {
    if (typeof goalMap[k] === "number" && goalMap[k] > 0) {
      progress[k] = { consumed: totals[k] ?? 0, goal: goalMap[k], pct: Math.round(((totals[k] ?? 0) / goalMap[k]) * 100) };
    }
  }

  return {
    date,
    isToday,
    meals,
    totals,
    totalsRange,
    goals,
    progress,
    workouts,
    trainingLoad: { day: Math.round((loads[date] ?? 0) * 10) / 10, ...load },
    metrics: dayMetrics,
    body: { measurements: bodyToday, latestWeightKg: latestWeight ?? null },
    note: notes[0] ?? null,
    cycle: profile.cycleTrackingEnabled ? cycle[0] ?? null : undefined,
    energy,
    insights,
  };
}
