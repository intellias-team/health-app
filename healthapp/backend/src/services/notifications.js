/**
 * Reminders & alerts. `decideNotifications(state, now)` is a pure function (unit-tested); the IO
 * around it (loading state, de-duplication markers, SNS publish) lives in `sendNotifications`.
 */
import { addDays, isoWeekStart, localParts } from "../lib/dates.js";
import { mean, stdDev } from "./stats.js";

export const DEFAULT_PREFS = Object.freeze({
  mealReminder: true,
  mealReminderTime: "13:00",
  hydration: true,
  hydrationTime: "15:00",
  recovery: true,
  sleepConsistency: true,
  proteinProgress: true,
  proteinTime: "18:00",
  deviceSync: true,
  quietStart: "22:00",
  quietEnd: "07:00",
});

export const THRESHOLDS = Object.freeze({
  readinessLow: 60,
  hrvBaselineFraction: 0.8,
  hrvBaselineMinDays: 14,
  bedtimeStdDevMin: 60,
  bedtimeMinNights: 5,
  proteinProgressBelow: 0.7,
  hydrationBelow: 0.5,
  syncStaleHours: 36,
});

/**
 * @typedef {Object} NotificationState
 * @property {string} timezone
 * @property {Partial<typeof DEFAULT_PREFS>} [prefs]
 * @property {{ proteinG?: number, waterMl?: number }} [goals]
 * @property {{ category: string, totals?: { proteinG?: number } }[]} todayMeals
 * @property {Record<string, any>} todayMetrics        merged metrics for today
 * @property {{ date: string, merged: Record<string, any> }[]} recentDays  up to 28 days before today (merged)
 * @property {{ provider: string, status: string, lastSyncAt?: string }[]} connections
 * @property {Set<string>|string[]} alreadySent       `<kind>#<date>` markers already sent
 */

/**
 * @typedef {{ type: string, kind: string, date: string, title: string, body: string }} Notification
 * `kind` + `date` form the de-dupe marker `NOTIFLOG#<kind>#<date>` (schema §2.2.1). Weekly
 * notifications use the Monday of the week as `date`.
 */

/** @param {{ kind: string, date: string }} n */
export const dedupeKey = (n) => `${n.kind}#${n.date}`;

const toMinutes = (hhmm) => {
  const [h, m] = String(hhmm).split(":").map(Number);
  return (h || 0) * 60 + (m || 0);
};

function inQuietHours(minuteOfDay, start, end) {
  const s = toMinutes(start);
  const e = toMinutes(end);
  return s > e ? minuteOfDay >= s || minuteOfDay < e : minuteOfDay >= s && minuteOfDay < e;
}

/**
 * Bedtime "minutes after noon" so times around midnight are continuous (22:30 → 630, 00:30 → 750).
 * @param {string} iso @param {string} tz
 */
export function bedtimeMinutesAfterNoon(iso, tz) {
  const p = localParts(iso, tz);
  return (p.hour * 60 + p.minute - 720 + 1440) % 1440;
}

/**
 * Decide which notifications to send now. Pure: no IO, no clock reads.
 * @param {NotificationState} state
 * @param {number|Date} now
 * @returns {Notification[]}
 */
export function decideNotifications(state, now) {
  const prefs = { ...DEFAULT_PREFS, ...(state.prefs ?? {}) };
  const tz = state.timezone || "UTC";
  const local = localParts(now, tz);
  const minute = local.hour * 60 + local.minute;
  const sent = new Set(state.alreadySent ?? []);
  const today = local.date;
  const out = [];
  const add = (n) => {
    if (!sent.has(dedupeKey(n))) out.push(n);
  };

  if (inQuietHours(minute, prefs.quietStart, prefs.quietEnd)) return [];

  // Meal logging reminder: nothing logged by the configured time.
  if (prefs.mealReminder && minute >= toMinutes(prefs.mealReminderTime) && state.todayMeals.length === 0) {
    add({ type: "meal_reminder", kind: "meal_reminder", date: today, title: "Log a meal?", body: "Nothing is logged yet today. A quick photo or voice note is enough." });
  }

  // Hydration: below half the water goal by the afternoon check.
  const waterGoal = state.goals?.waterMl;
  const water = state.todayMetrics?.waterMl ?? 0;
  if (prefs.hydration && waterGoal && minute >= toMinutes(prefs.hydrationTime) && water < waterGoal * THRESHOLDS.hydrationBelow) {
    add({ type: "hydration", kind: "hydration", date: today, title: "Hydration check", body: `You've logged ${Math.round(water)} ml of your ${Math.round(waterGoal)} ml water goal so far.` });
  }

  // Low recovery: readiness < 60, or HRV < 80 % of the 28-day baseline.
  if (prefs.recovery && local.hour >= 7) {
    const readiness = state.todayMetrics?.readinessScore;
    const hrv = state.todayMetrics?.hrvMs;
    const baselineValues = state.recentDays.map((d) => d.merged?.hrvMs).filter((x) => typeof x === "number");
    const baseline = baselineValues.length >= THRESHOLDS.hrvBaselineMinDays ? mean(baselineValues) : null;
    const lowReadiness = typeof readiness === "number" && readiness < THRESHOLDS.readinessLow;
    const lowHrv = typeof hrv === "number" && baseline !== null && hrv < baseline * THRESHOLDS.hrvBaselineFraction;
    if (lowReadiness || lowHrv) {
      const reason = lowReadiness ? `readiness is ${readiness}` : `HRV is ${Math.round(hrv)} ms vs your ~${Math.round(baseline)} ms baseline`;
      add({
        type: "low_recovery", kind: "low_recovery", date: today, title: "Recovery is lower today",
        body: `Your ${reason}. An easier session, enough food and an early night can help. If you feel unwell, consider checking in with a clinician.`,
      });
    }
  }

  // Sleep consistency: bedtime standard deviation > 60 min over the last 7 nights (weekly at most).
  if (prefs.sleepConsistency && local.hour >= 20) {
    const last7 = state.recentDays.filter((d) => d.date >= addDays(today, -7));
    const bedtimes = last7.map((d) => d.merged?.bedtimeStart).filter((b) => b && !Number.isNaN(Date.parse(b))).map((b) => bedtimeMinutesAfterNoon(b, tz));
    const sd = bedtimes.length >= THRESHOLDS.bedtimeMinNights ? stdDev(bedtimes) : null;
    if (sd !== null && sd > THRESHOLDS.bedtimeStdDevMin) {
      add({
        type: "sleep_consistency", kind: "sleep_consistency", date: isoWeekStart(today), title: "Bedtime has varied this week",
        body: `Your bedtime varied by about ${Math.round(sd)} minutes this week. A more regular wind-down time can make sleep feel more consistent.`,
      });
    }
  }

  // Protein goal progress at 18:00.
  const proteinGoal = state.goals?.proteinG;
  if (prefs.proteinProgress && proteinGoal && minute >= toMinutes(prefs.proteinTime) && state.todayMeals.length > 0) {
    const protein = state.todayMeals.reduce((s, m) => s + (m.totals?.proteinG ?? 0), 0);
    if (protein < proteinGoal * THRESHOLDS.proteinProgressBelow) {
      add({ type: "protein_progress", kind: "protein_progress", date: today, title: "Protein progress", body: `You're at ${Math.round(protein)} g of your ${Math.round(proteinGoal)} g protein goal today.` });
    }
  }

  // Connected-device sync problems.
  if (prefs.deviceSync) {
    const nowMs = new Date(now).getTime();
    for (const c of state.connections ?? []) {
      if (c.status === "revoked") continue;
      const stale = c.status === "connected" && c.lastSyncAt && nowMs - Date.parse(c.lastSyncAt) > THRESHOLDS.syncStaleHours * 3_600_000;
      if (c.status === "error" || stale) {
        const name = providerName(c.provider);
        add({
          type: "device_sync", kind: `device_sync:${c.provider}`, date: today, title: `${name} isn't syncing`,
          body: c.status === "error" ? `We couldn't sync ${name}. Reconnect it in Settings → Data Sources.` : `${name} hasn't synced for over a day. Open the app or check the device's connection.`,
        });
      }
    }
  }
  return out;
}

function providerName(provider) {
  if (provider === "oura") return "Oura";
  if (provider === "healthkit") return "Apple Health";
  if (provider.startsWith("bodyscale:")) return "Your smart scale";
  if (provider.startsWith("foodscale:")) return "Your food scale";
  return provider;
}

/**
 * Build the SNS message for APNs (production + sandbox keys).
 * @param {Notification} n
 */
export function apnsMessage(n) {
  const payload = JSON.stringify({ aps: { alert: { title: n.title, body: n.body }, sound: "default", "thread-id": n.type }, type: n.type });
  return JSON.stringify({ default: n.body, APNS: payload, APNS_SANDBOX: payload });
}
