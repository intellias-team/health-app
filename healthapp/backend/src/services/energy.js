/**
 * Daily Energy: resting + active expenditure, intake, balance — and a neutral fueling insight.
 *
 * Language policy: the app never praises a deficit or frames under-eating as success. When intake
 * looks low relative to expenditure, the message is about recovery and fueling, phrased neutrally,
 * and always acknowledges that unlogged food may explain the gap.
 */

/**
 * Mifflin–St Jeor resting energy estimate (kcal/day). Unknown sex uses the midpoint constant.
 * @param {{ weightKg?: number, heightCm?: number, age?: number, sex?: string }} p
 * @returns {number|null}
 */
export function estimateRestingKcal({ weightKg, heightCm, age, sex }) {
  if (!weightKg || !heightCm || !age) return null;
  const s = sex === "male" ? 5 : sex === "female" ? -161 : -78;
  return Math.round(10 * weightKg + 6.25 * heightCm - 5 * age + s);
}

/**
 * @typedef {Object} DailyEnergy
 * @property {number|null} restingKcal
 * @property {"measured"|"estimated"|null} restingSource
 * @property {number|null} activeKcal
 * @property {number|null} totalKcal       total daily energy expenditure (TDEE)
 * @property {number|null} intakeKcal
 * @property {number|null} balanceKcal     intake − expenditure
 * @property {number} mealsLogged
 * @property {{ intake: boolean, expenditure: boolean }} complete
 */

/**
 * @param {{
 *   merged?: Record<string, any>,
 *   meals?: { totals?: { kcal?: number }, deleted?: boolean }[],
 *   profile?: { birthYear?: number, heightCm?: number, sex?: string },
 *   weightKg?: number,
 *   year?: number,
 * }} input
 * @returns {DailyEnergy}
 */
export function computeDailyEnergy({ merged = {}, meals = [], profile = {}, weightKg, year = new Date().getUTCFullYear() }) {
  const liveMeals = meals.filter((m) => !m.deleted);
  const intakeKcal = liveMeals.length ? Math.round(liveMeals.reduce((s, m) => s + (m.totals?.kcal ?? 0), 0)) : null;

  let restingKcal = typeof merged.restingKcal === "number" ? merged.restingKcal : null;
  let restingSource = restingKcal !== null ? "measured" : null;
  if (restingKcal === null) {
    const age = profile.birthYear ? year - profile.birthYear : undefined;
    restingKcal = estimateRestingKcal({ weightKg, heightCm: profile.heightCm, age, sex: profile.sex });
    if (restingKcal !== null) restingSource = "estimated";
  }
  const activeKcal = typeof merged.activeKcal === "number" ? merged.activeKcal : null;
  const totalKcal = restingKcal !== null ? Math.round(restingKcal + (activeKcal ?? 0)) : null;
  const balanceKcal = totalKcal !== null && intakeKcal !== null ? intakeKcal - totalKcal : null;
  return {
    restingKcal: restingKcal !== null ? Math.round(restingKcal) : null,
    restingSource,
    activeKcal,
    totalKcal,
    intakeKcal,
    balanceKcal,
    mealsLogged: liveMeals.length,
    complete: { intake: intakeKcal !== null, expenditure: restingKcal !== null && activeKcal !== null },
  };
}

/** Thresholds for the fueling insight. */
export const FUELING_THRESHOLDS = Object.freeze({
  lowIntakeRatio: 0.6,     // intake < 60 % of expenditure
  eveningHour: 18,         // only judge "today" after 6 pm local
  multiDayDeficit: 0.35,   // 3-day average deficit > 35 %
  highLoadAcwr: 1.3,       // acute:chronic ratio considered a high-load day
  highLoadSession: 150,    // TRIMP of the day considered high load
});

/**
 * @typedef {Object} Insight
 * @property {"fueling"|"data_incomplete"} type
 * @property {"info"} severity
 * @property {string} title
 * @property {string} message
 * @property {Record<string, unknown>} [evidence]
 */

const pct = (x) => Math.round(x * 100);

/**
 * Neutral recovery-and-fueling insight. Returns null when nothing is worth saying.
 *
 * @param {{
 *   today: DailyEnergy,
 *   previousDays?: DailyEnergy[],   // up to the 2 preceding days (oldest first)
 *   localHour: number,
 *   isToday: boolean,
 *   dayLoad?: number,               // TRIMP of the day
 *   acwr?: number|null,             // acute:chronic workload ratio
 * }} input
 * @returns {Insight|null}
 */
export function fuelingInsight({ today, previousDays = [], localHour, isToday, dayLoad = 0, acwr = null }) {
  const t = FUELING_THRESHOLDS;

  if (today.totalKcal === null) {
    return {
      type: "data_incomplete", severity: "info", title: "Energy data incomplete",
      message: "We can't estimate today's energy use yet — add your height, birth year and a body weight, or connect a source for resting and active energy.",
    };
  }
  if (today.intakeKcal === null) {
    if (isToday && localHour < t.eveningHour) return null; // the day is still young
    return {
      type: "data_incomplete", severity: "info", title: "No meals logged",
      message: "No meals are logged for this day, so energy balance can't be shown. If you ate but didn't log, the numbers here won't reflect it.",
    };
  }

  const ratio = today.intakeKcal / today.totalKcal;
  const highLoad = dayLoad >= t.highLoadSession || (acwr !== null && acwr >= t.highLoadAcwr);
  const lowToday = ratio < t.lowIntakeRatio && (!isToday || localHour >= t.eveningHour || highLoad);

  const window = [...previousDays.slice(-2), today].filter((d) => d.totalKcal && d.intakeKcal !== null);
  let avgDeficit = null;
  if (window.length === 3) {
    avgDeficit = window.reduce((s, d) => s + (d.totalKcal - d.intakeKcal) / d.totalKcal, 0) / 3;
  }
  const lowTrend = avgDeficit !== null && avgDeficit > t.multiDayDeficit;

  if (!lowToday && !lowTrend) return null;

  const parts = [];
  if (lowToday) {
    parts.push(`Logged intake is about ${pct(ratio)}% of your estimated energy use${isToday ? " so far today" : " for this day"}.`);
  }
  if (lowTrend) {
    parts.push(`Over the last 3 days, logged intake has averaged about ${pct(1 - avgDeficit)}% of estimated energy use.`);
  }
  if (highLoad) parts.push("Training load is relatively high, and recovery depends on having enough energy and protein.");
  parts.push("If that matches what you actually ate, consider whether a balanced meal or snack fits your plans. If some food isn't logged yet, these numbers will be lower than reality.");

  return {
    type: "fueling",
    severity: "info",
    title: "Recovery & fueling",
    message: parts.join(" "),
    evidence: {
      intakeKcal: today.intakeKcal,
      totalKcal: today.totalKcal,
      intakeRatio: Math.round(ratio * 100) / 100,
      threeDayAvgDeficit: avgDeficit !== null ? Math.round(avgDeficit * 100) / 100 : null,
      highLoad,
      expenditureEstimated: today.restingSource === "estimated" || !today.complete.expenditure,
    },
  };
}
