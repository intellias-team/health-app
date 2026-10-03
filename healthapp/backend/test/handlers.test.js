import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler as createProfile } from "../src/handlers/profile.js";
import { createHandler as createHealth } from "../src/handlers/health.js";
import { createHandler as createPurge } from "../src/handlers/tombstonePurge.js";
import { silentLogger } from "../src/lib/logger.js";
import { connectionKey, mealKey, profileKey } from "../src/lib/keys.js";
import { cycleDays } from "../src/services/trends.js";
import { apiEvent, createFakeMedia, createTestRepo, parse, SUB, OTHER_SUB } from "./helpers/fakes.js";

test("DELETE /v1/me removes every USER# item (batched), the S3 prefix and revokes Oura", async () => {
  const { repo, doc } = createTestRepo();
  const media = createFakeMedia({ [`users/${SUB}/meals/a.jpg`]: Buffer.from("1"), [`users/${SUB}/exports/x.zip`]: Buffer.from("2"), [`users/${OTHER_SUB}/meals/b.jpg`]: Buffer.from("3") });
  for (let i = 0; i < 60; i++) {
    await repo.putVersioned(SUB, mealKey(SUB, "2026-10-03", `m${i}`), "meal", `m${i}`, { date: "2026-10-03", items: [] });
  }
  await repo.putVersioned(SUB, connectionKey(SUB, "oura"), "connection", "oura", { provider: "oura", status: "connected" }, { extra: { tokenCiphertext: "x" } });
  await repo.putVersioned(OTHER_SUB, profileKey(OTHER_SUB), "profile", "profile", { displayName: "other" });
  const revoked = [];
  const h = createProfile({ repo, media, push: null, logger: silentLogger, revokeOura: async (sub) => { revoked.push(sub); } });

  const res = parse(await h(apiEvent({ method: "DELETE", path: "/v1/me" })));
  assert.equal(res.status, 202);
  assert.equal(res.body.itemsDeleted, 61);
  assert.deepEqual(revoked, [SUB]);
  assert.deepEqual([...media.store.keys()], [`users/${OTHER_SUB}/meals/b.jpg`]);
  assert.equal((await repo.listUserItems(SUB)).length, 0);
  assert.ok(await repo.get(profileKey(OTHER_SUB)), "other users untouched");
  const batches = doc.calls.filter(([op]) => op === "batchWrite");
  assert.equal(batches.length, 3, "61 items → 25 + 25 + 11");
});

test("profile, goals, connections: public views never leak tokens", async () => {
  const { repo } = createTestRepo();
  const h = createProfile({ repo, media: createFakeMedia(), push: null, logger: silentLogger });
  const put = parse(await h(apiEvent({ method: "PUT", path: "/v1/me", body: { displayName: "Sam", timezone: "Europe/Berlin", heightCm: 180, PK: "USER#evil" } })));
  assert.equal(put.status, 200);
  assert.equal(put.body.profile.displayName, "Sam");
  assert.equal(put.body.profile.PK, undefined);
  await repo.putVersioned(SUB, connectionKey(SUB, "oura"), "connection", "oura", { provider: "oura", status: "connected", ouraUserId: "u" }, { extra: { tokenCiphertext: "secret", GSI2PK: "OURAUSER#u", GSI2SK: "CONNECTION" } });
  const me = parse(await h(apiEvent({ path: "/v1/me" })));
  assert.equal(me.body.connections.length, 1);
  assert.equal(JSON.stringify(me.body).includes("secret"), false);
  const upd = parse(await h(apiEvent({ method: "PUT", path: "/v1/connections/oura", body: { enabledMetrics: ["sleepScore"], status: "connected" } })));
  assert.equal(upd.status, 200);
  assert.equal((await repo.get(connectionKey(SUB, "oura"))).tokenCiphertext, "secret", "token preserved across permission edits");
  const noOauth = parse(await h(apiEvent({ method: "PUT", path: "/v1/connections/healthkit", body: { enabledMetrics: ["steps"], status: "connected" } })));
  assert.equal(noOauth.status, 200);
  const bad = parse(await h(apiEvent({ method: "PUT", path: "/v1/connections/fitbit", body: { status: "connected" } })));
  assert.equal(bad.status, 400);
});

test("export writes a zip under the user's exports prefix and returns a presigned URL", async () => {
  const { repo } = createTestRepo();
  const media = createFakeMedia();
  const h = createProfile({ repo, media, push: null, logger: silentLogger });
  await repo.putVersioned(SUB, profileKey(SUB), "profile", "profile", { displayName: "Sam" });
  const res = parse(await h(apiEvent({ method: "POST", path: "/v1/me/export" })));
  assert.equal(res.status, 200);
  const [key] = [...media.store.keys()];
  assert.match(key, new RegExp(`^users/${SUB}/exports/.+\\.zip$`));
  assert.equal(media.store.get(key).readUInt32LE(0), 0x04034b50, "zip signature");
  assert.match(res.body.downloadUrl, /exports/);
});

test("health: metrics batch + merged read, trends with weekly agg, single-source HRV, compare with caveat", async () => {
  const { repo, now } = createTestRepo();
  now.set("2026-10-03T10:00:00Z");
  const h = createHealth({ repo, logger: silentLogger });
  const days = [];
  for (let i = 0; i < 14; i++) {
    const date = new Date(Date.UTC(2026, 8, 20 + i)).toISOString().slice(0, 10);
    days.push({ date, source: "healthkit", metrics: { steps: 5000 + i * 500, hrvMs: 40 } });
    days.push({ date, source: "oura", metrics: { sleepScore: 60 + i, ...(i >= 7 ? { hrvMs: 70, hrvMethod: "rmssd" } : {}) } });
  }
  const res1 = parse(await h(apiEvent({ method: "POST", path: "/v1/metrics/daily", body: { days: [...days, ...days.slice(0, 4)] } })));
  assert.equal(res1.status, 400, "batch > 31 entries rejected");
  assert.equal(parse(await h(apiEvent({ method: "POST", path: "/v1/metrics/daily", body: { days: days.slice(0, 14) } }))).body.upserted, 14);
  assert.equal(parse(await h(apiEvent({ method: "POST", path: "/v1/metrics/daily", body: { days: days.slice(14) } }))).body.upserted, 14);

  const read = parse(await h(apiEvent({ path: "/v1/metrics/daily", query: { from: "2026-10-01", to: "2026-10-03" } })));
  assert.equal(read.body.days[0].merged.hrvMs, 70);
  assert.equal(read.body.days[0].merged.hrvMethod, "rmssd");
  assert.ok(read.body.days[0].bySource.healthkit);

  const trend = parse(await h(apiEvent({ path: "/v1/trends/steps", query: { range: "30d", agg: "week" } })));
  assert.equal(trend.body.unit, "count");
  assert.ok(trend.body.points.length >= 4 && trend.body.points.length <= 6);
  const hrv = parse(await h(apiEvent({ path: "/v1/trends/hrvMs", query: { range: "30d" } })));
  const hrvValues = hrv.body.points.map((p) => p.value).filter((v) => v !== null);
  assert.ok(hrvValues.every((v) => v === 70), "Oura RMSSD only, never mixed with HealthKit SDNN");

  const cmp = parse(await h(apiEvent({ path: "/v1/trends/compare", query: { x: "steps", y: "sleepScore", range: "30d", lagDays: "1" } })));
  assert.equal(cmp.status, 200);
  assert.equal(cmp.body.n, 13);
  assert.equal(cmp.body.pearsonR, 1);
  assert.match(cmp.body.caveat, /not causation/);
  assert.equal(parse(await h(apiEvent({ path: "/v1/trends/bogus" }))).status, 400);
});

test("day summary: totals, energy balance and a neutral fueling insight", async () => {
  const { repo, now } = createTestRepo();
  now.set("2026-10-03T18:30:00Z");
  const h = createHealth({ repo, logger: silentLogger });
  await repo.putVersioned(SUB, profileKey(SUB), "profile", "profile", { timezone: "UTC", birthYear: 1990, heightCm: 175, sex: "female" });
  await h(apiEvent({ method: "POST", path: "/v1/metrics/daily", body: { days: [{ date: "2026-10-03", source: "healthkit", metrics: { restingKcal: 1500, activeKcal: 900 } }] } }));
  await repo.putVersioned(SUB, mealKey(SUB, "2026-10-03", "m1"), "meal", "m1", { date: "2026-10-03", loggedAt: "2026-10-03T08:00:00Z", category: "breakfast", items: [], totals: { kcal: 600, proteinG: 20 }, totalsRange: { kcalLow: 500, kcalHigh: 700 } });
  await h(apiEvent({ method: "POST", path: "/v1/workouts", body: { workouts: [{ id: "w1", start: "2026-10-03T07:00:00Z", end: "2026-10-03T08:00:00Z", type: "run", source: "healthkit", durationMin: 60, avgHr: 165 }] } }));
  const day = parse(await h(apiEvent({ path: "/v1/day/2026-10-03" })));
  assert.equal(day.status, 200);
  assert.equal(day.body.energy.totalKcal, 2400);
  assert.equal(day.body.energy.intakeKcal, 600);
  assert.equal(day.body.energy.balanceKcal, -1800);
  assert.equal(day.body.workouts.length, 1);
  assert.ok(day.body.trainingLoad.day > 0);
  const fuel = day.body.insights.find((i) => i.type === "fueling");
  assert.ok(fuel);
  assert.doesNotMatch(fuel.message, /great job|well done|keep it up/i);
  assert.equal(day.body.totalsRange.kcalLow, 500);
});

test("cycle endpoint 403 unless opted in; cycle day computation", async () => {
  const { repo } = createTestRepo();
  const h = createHealth({ repo, logger: silentLogger });
  assert.equal(parse(await h(apiEvent({ method: "PUT", path: "/v1/cycle/2026-10-01", body: { flow: "medium" } }))).status, 403);
  await repo.putVersioned(SUB, profileKey(SUB), "profile", "profile", { cycleTrackingEnabled: true });
  assert.equal(parse(await h(apiEvent({ method: "PUT", path: "/v1/cycle/2026-10-01", body: { flow: "medium" } }))).status, 200);
  const pts = cycleDays([{ date: "2026-09-30", flow: "light" }, { date: "2026-10-01", flow: "medium" }], ["2026-09-29", "2026-09-30", "2026-10-03"]);
  assert.deepEqual(pts.map((p) => p.value), [null, 1, 4]);
});

test("tombstone purge: deletes old tombstones and re-deletes recent meal photos", async () => {
  const { repo, now } = createTestRepo();
  const media = createFakeMedia({ [`users/${SUB}/meals/m2.jpg`]: Buffer.from("x") });
  now.set("2026-06-01T00:00:00Z");
  await repo.putVersioned(SUB, mealKey(SUB, "2026-06-01", "m1"), "meal", "m1", { date: "2026-06-01" });
  await repo.tombstone(SUB, mealKey(SUB, "2026-06-01", "m1"), "meal", "m1");
  now.set("2026-10-03T00:00:00Z");
  await repo.putVersioned(SUB, mealKey(SUB, "2026-10-02", "m2"), "meal", "m2", { date: "2026-10-02" });
  await repo.tombstone(SUB, mealKey(SUB, "2026-10-02", "m2"), "meal", "m2");
  const summary = await createPurge({ repo, media, now, logger: silentLogger })();
  assert.deepEqual(summary, { purged: 1, photosDeleted: 1 });
  assert.equal(await repo.get(mealKey(SUB, "2026-06-01", "m1"), { includeDeleted: true }), undefined);
  assert.equal(media.store.size, 0);
});
