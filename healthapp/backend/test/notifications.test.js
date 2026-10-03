import { test } from "node:test";
import assert from "node:assert/strict";
import { apnsMessage, bedtimeMinutesAfterNoon, decideNotifications, dedupeKey } from "../src/services/notifications.js";
import { createHandler } from "../src/handlers/notificationsScheduled.js";
import { silentLogger } from "../src/lib/logger.js";
import { deviceKey, gsi2DeviceKeys, goalsKey, profileKey } from "../src/lib/keys.js";
import { createTestRepo, SUB } from "./helpers/fakes.js";
import { addDays } from "../src/lib/dates.js";

const baseState = (over = {}) => ({
  timezone: "Europe/Berlin",
  prefs: {},
  goals: { proteinG: 120, waterMl: 2000 },
  todayMeals: [{ category: "breakfast", totals: { proteinG: 30 } }],
  todayMetrics: { waterMl: 1500 },
  recentDays: [],
  connections: [],
  alreadySent: [],
  ...over,
});
const at = (localIso) => new Date(localIso); // pass explicit offsets
const types = (ns) => ns.map((n) => n.type).sort();

test("meal reminder only after configured time with no meals, de-duplicated by kind#date", () => {
  const noMeals = baseState({ todayMeals: [] });
  assert.deepEqual(types(decideNotifications(noMeals, at("2026-10-03T12:30:00+02:00"))), []);
  const ns = decideNotifications(noMeals, at("2026-10-03T13:05:00+02:00"));
  assert.deepEqual(types(ns), ["meal_reminder"]);
  assert.equal(dedupeKey(ns[0]), "meal_reminder#2026-10-03");
  assert.deepEqual(decideNotifications({ ...noMeals, alreadySent: ["meal_reminder#2026-10-03"] }, at("2026-10-03T13:05:00+02:00")), []);
});

test("quiet hours suppress everything", () => {
  assert.deepEqual(decideNotifications(baseState({ todayMeals: [] }), at("2026-10-03T23:30:00+02:00")), []);
});

test("hydration below 50 % of goal after 15:00", () => {
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { waterMl: 500 } }), at("2026-10-03T15:10:00+02:00"))), ["hydration"]);
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { waterMl: 1200 } }), at("2026-10-03T15:10:00+02:00"))), []);
});

test("low recovery: readiness < 60 or HRV < 80 % of 28-day baseline (needs ≥ 14 days)", () => {
  const days = (n, hrv) => Array.from({ length: n }, (_, i) => ({ date: `2026-09-${String(10 + i).padStart(2, "0")}`, merged: { hrvMs: hrv } }));
  const morning = at("2026-10-03T08:00:00+02:00");
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { readinessScore: 55 } }), morning)), ["low_recovery"]);
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { hrvMs: 40 }, recentDays: days(20, 60) }), morning)), ["low_recovery"]);
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { hrvMs: 50 }, recentDays: days(20, 60) }), morning)), [], "50 ≥ 48");
  assert.deepEqual(types(decideNotifications(baseState({ todayMetrics: { hrvMs: 30 }, recentDays: days(10, 60) }), morning)), [], "baseline too short");
  const msg = decideNotifications(baseState({ todayMetrics: { readinessScore: 55 } }), morning)[0].body;
  assert.doesNotMatch(msg, /disease|illness|diagnos/i);
});

test("sleep consistency: bedtime SD > 60 min over 7 nights, weekly dedupe; handles midnight wrap", () => {
  assert.equal(bedtimeMinutesAfterNoon("2026-10-02T22:30:00Z", "UTC"), 630);
  assert.equal(bedtimeMinutesAfterNoon("2026-10-03T00:30:00Z", "UTC"), 750);
  const mk = (times) => times.map((t, i) => {
    const date = addDays("2026-09-27", i);
    return { date, merged: { bedtimeStart: `${date}T${t}:00Z` } };
  });
  const evening = at("2026-10-03T21:00:00Z");
  const steady = baseState({ timezone: "UTC", goals: {}, recentDays: mk(["22:00", "22:15", "21:50", "22:30", "22:05", "22:20"]) });
  assert.deepEqual(types(decideNotifications(steady, evening)), []);
  const erratic = baseState({ timezone: "UTC", goals: {}, recentDays: mk(["21:00", "23:59", "20:30", "23:30", "21:15", "23:45"]) });
  const ns = decideNotifications(erratic, evening);
  assert.deepEqual(types(ns), ["sleep_consistency"]);
  assert.equal(ns[0].date, "2026-09-28", "weekly marker uses Monday");
});

test("protein progress at 18:00 and device sync failures", () => {
  assert.deepEqual(types(decideNotifications(baseState(), at("2026-10-03T18:05:00+02:00"))), ["protein_progress"]);
  const conns = [
    { provider: "oura", status: "error" },
    { provider: "bodyscale:abc", status: "connected", lastSyncAt: "2026-10-01T08:00:00Z" },
    { provider: "healthkit", status: "connected", lastSyncAt: "2026-10-03T08:00:00Z" },
    { provider: "foodscale:x", status: "revoked", lastSyncAt: "2026-01-01T00:00:00Z" },
  ];
  const ns = decideNotifications(baseState({ connections: conns, goals: {} }), at("2026-10-03T10:00:00+02:00"));
  assert.deepEqual(ns.map((n) => n.kind).sort(), ["device_sync:bodyscale:abc", "device_sync:oura"]);
});

test("APNs payload carries both APNS and APNS_SANDBOX", () => {
  const m = JSON.parse(apnsMessage({ type: "hydration", kind: "hydration", date: "d", title: "T", body: "B" }));
  assert.deepEqual(JSON.parse(m.APNS).aps.alert, { title: "T", body: "B" });
  assert.equal(m.APNS, m.APNS_SANDBOX);
});

test("scheduled run: loads state, writes NOTIFLOG marker once, publishes via SNS, disables dead endpoints", async () => {
  const { repo, now } = createTestRepo();
  now.set("2026-10-03T11:30:00Z"); // 13:30 Berlin
  await repo.putVersioned(SUB, profileKey(SUB), "profile", "profile", { timezone: "Europe/Berlin" });
  await repo.putVersioned(SUB, goalsKey(SUB), "goals", "goals", { proteinG: 100 });
  await repo.putVersioned(SUB, deviceKey(SUB, "d1"), "device", "d1", { apnsToken: "ab", endpointArn: "arn:ep1", enabled: true, notificationPrefs: {} }, { extra: gsi2DeviceKeys(SUB, "d1") });
  await repo.putVersioned(SUB, deviceKey(SUB, "d2"), "device", "d2", { apnsToken: "cd", endpointArn: "arn:dead", enabled: true, notificationPrefs: {} }, { extra: gsi2DeviceKeys(SUB, "d2") });
  const published = [];
  const { EndpointDisabledError } = await import("../src/lib/messaging.js");
  const push = { publish: async (arn, msg) => { if (arn === "arn:dead") throw new EndpointDisabledError(); published.push([arn, JSON.parse(msg)]); } };
  const run = createHandler({ repo, push, now, logger: silentLogger });

  const first = await run();
  assert.deepEqual(first, { users: 1, sent: 1 });
  assert.equal(published[0][0], "arn:ep1");
  assert.match(published[0][1].default, /Nothing is logged/);
  assert.equal((await repo.get(deviceKey(SUB, "d2"))).enabled, false);
  const second = await run();
  assert.equal(second.sent, 0, "marker prevents re-sending");
});
