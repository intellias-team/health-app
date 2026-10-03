/**
 * Calendar-date helpers. Dates are `yyyy-mm-dd` strings in the user's timezone; arithmetic is
 * done on UTC midnight so it is DST-safe.
 */

const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

/** @param {string} s */
export function isDate(s) {
  if (typeof s !== "string" || !DATE_RE.test(s)) return false;
  const d = new Date(`${s}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s;
}

/** @param {string} date @param {number} n */
export function addDays(date, n) {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

/** Inclusive number of days between two dates (to - from). */
export function daysBetween(from, to) {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/** Inclusive list of dates. @param {string} from @param {string} to */
export function dateRange(from, to) {
  const out = [];
  for (let d = from; d <= to; d = addDays(d, 1)) out.push(d);
  return out;
}

/**
 * Local calendar parts for an instant in an IANA timezone.
 * @param {Date|number|string} instant @param {string} [timeZone]
 * @returns {{ date: string, hour: number, minute: number, weekday: number }}
 */
export function localParts(instant, timeZone = "UTC") {
  const d = new Date(instant);
  let tz = timeZone;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
  } catch {
    tz = "UTC";
  }
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", hourCycle: "h23", weekday: "short",
    }).formatToParts(d).map((p) => [p.type, p.value]),
  );
  const weekdays = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return {
    date: `${parts.year}-${parts.month}-${parts.day}`,
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    weekday: weekdays[parts.weekday] ?? 0,
  };
}

/** Local date string for an instant. */
export function localDate(instant, timeZone) {
  return localParts(instant, timeZone).date;
}

/** Monday of the ISO week containing `date`. */
export function isoWeekStart(date) {
  const dow = new Date(`${date}T00:00:00Z`).getUTCDay(); // 0 = Sunday
  return addDays(date, dow === 0 ? -6 : 1 - dow);
}

/** Epoch seconds `days` after `nowMs`. */
export function ttlAfterDays(nowMs, days) {
  return Math.floor(nowMs / 1000) + Math.round(days * 86_400);
}
