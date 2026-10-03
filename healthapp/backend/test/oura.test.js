import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { createOuraClient, mapOuraDailyMetrics, mapOuraWorkouts, verifySubscriptionChallenge, verifyWebhookSignature } from "../src/services/oura.js";
import { syncOuraForUser } from "../src/services/ouraSync.js";
import { createTokenVault } from "../src/lib/kms.js";
import { createHandler as createOuraHandler } from "../src/handlers/oura.js";
import { createHandler as createWorker } from "../src/handlers/ouraWebhookWorker.js";
import { createHandler as createScheduled } from "../src/handlers/ouraSyncScheduled.js";
import { silentLogger } from "../src/lib/logger.js";
import { connectionKey, dayKey, oauthStateKey } from "../src/lib/keys.js";
import { apiEvent, createFakeFetch, createFakeKms, createTestRepo, parse, SUB } from "./helpers/fakes.js";

const SLEEP = [
  { id: "s-nap", day: "2026-10-02", type: "late_nap", total_sleep_duration: 1800 },
  {
    id: "s1", day: "2026-10-02", type: "long_sleep", total_sleep_duration: 26_400, deep_sleep_duration: 5400, rem_sleep_duration: 6000,
    light_sleep_duration: 15_000, awake_time: 2400, time_in_bed: 28_800, lowest_heart_rate: 48, average_hrv: 62, average_breath: 14.5,
    bedtime_start: "2026-10-01T23:10:00+02:00",
  },
];
const COLLECTIONS = {
  daily_sleep: [{ day: "2026-10-02", score: 82 }],
  daily_readiness: [{ day: "2026-10-02", score: 77, temperature_deviation: -0.12 }],
  daily_activity: [{ day: "2026-10-02", steps: 10_234, active_calories: 520, total_calories: 2480, score: 88 }],
  sleep: SLEEP,
  daily_spo2: [{ day: "2026-10-02", spo2_percentage: { average: 97.2 } }],
  workout: [{ id: "w1", activity: "running", start_datetime: "2026-10-02T07:00:00+02:00", end_datetime: "2026-10-02T07:45:00+02:00", calories: 412.4, distance: 7012.3, intensity: "hard" }],
};

test("Oura → daily metrics mapping (schema §2.2.3)", () => {
  const m = mapOuraDailyMetrics(COLLECTIONS).get("2026-10-02");
  assert.deepEqual(m, {
    sleepScore: 82, readinessScore: 77, tempDeviationC: -0.12, steps: 10_234, activeKcal: 520, restingKcal: 1960, activityScore: 88, spo2Pct: 97.2,
    sleepMinutes: 440,
    sleepStages: { coreMin: 250, deepMin: 90, remMin: 100, awakeMin: 40, inBedMin: 480, napMin: 30 },
    restingHr: 48, restingHrMethod: "sleepLowest", hrvMs: 62, hrvMethod: "rmssd", respiratoryRate: 14.5,
    bedtimeStart: "2026-10-01T21:10:00.000Z",
  });
  const [w] = mapOuraWorkouts(COLLECTIONS.workout);
  assert.deepEqual(w, { id: "oura-w1", start: "2026-10-02T05:00:00.000Z", end: "2026-10-02T05:45:00.000Z", type: "running", source: "oura", durationMin: 45, activeKcal: 412, distanceM: 7012, intensity: "hard", externalId: "w1" });
});

test("webhook signature: HMAC-SHA256(secret, timestamp + body), constant-time, ≤ 5 min skew", () => {
  const secret = "client-secret";
  const body = JSON.stringify({ event_type: "update", data_type: "daily_sleep", object_id: "abc", user_id: "u1" });
  const now = Date.parse("2026-10-03T12:00:00Z");
  const ts = String(Math.floor(now / 1000));
  const sig = createHmac("sha256", secret).update(ts + body).digest("hex").toUpperCase();
  assert.equal(verifyWebhookSignature({ rawBody: body, signature: sig, timestamp: ts, clientSecret: secret, now }), true);
  assert.equal(verifyWebhookSignature({ rawBody: body + " ", signature: sig, timestamp: ts, clientSecret: secret, now }), false, "tampered body");
  assert.equal(verifyWebhookSignature({ rawBody: body, signature: sig, timestamp: ts, clientSecret: "other", now }), false, "wrong secret");
  assert.equal(verifyWebhookSignature({ rawBody: body, signature: sig, timestamp: ts, clientSecret: secret, now: now + 6 * 60_000 }), false, "stale");
  assert.equal(verifyWebhookSignature({ rawBody: body, signature: "zz", timestamp: ts, clientSecret: secret, now }), false, "garbage");
  assert.equal(verifyWebhookSignature({ rawBody: body, signature: undefined, timestamp: ts, clientSecret: secret, now }), false);
  assert.deepEqual(verifySubscriptionChallenge({ verificationToken: "tok", challenge: "c123", expectedToken: "tok" }), { challenge: "c123" });
  assert.equal(verifySubscriptionChallenge({ verificationToken: "bad", challenge: "c123", expectedToken: "tok" }), null);
});

test("token vault: envelope encryption round trip bound to the user", async () => {
  const vault = createTokenVault({ kms: createFakeKms(), keyId: "alias/token" });
  const env = await vault.encrypt(SUB, { access_token: "a", refresh_token: "r", expires_at: 1 });
  assert.ok(!Buffer.from(env, "base64").toString().includes("\"a\""));
  assert.deepEqual(await vault.decrypt(SUB, env), { access_token: "a", refresh_token: "r", expires_at: 1 });
  await assert.rejects(vault.decrypt("someone-else", env));
});

/** Fake Oura API with pagination on daily_activity. */
function ouraFetch(counter = { token: 0 }) {
  return createFakeFetch([
    ["/oauth/token", (url, init) => {
      counter.token++;
      const p = new URLSearchParams(init.body);
      assert.equal(p.get("client_secret"), "secret");
      return { json: { access_token: `at-${counter.token}`, refresh_token: `rt-${counter.token}`, expires_in: 86400, scope: "personal daily" } };
    }],
    ["/oauth/revoke", () => ({ json: {} })],
    ["personal_info", () => ({ json: { id: "oura-user-1", age: 35 } })],
    [/usercollection\/daily_activity\?/, (url) => {
      const u = new URL(url);
      return u.searchParams.get("next_token") === "p2"
        ? { json: { data: [{ day: "2026-10-03", steps: 4000, active_calories: 200, total_calories: 1900, score: 70 }], next_token: null } }
        : { json: { data: COLLECTIONS.daily_activity, next_token: "p2" } };
    }],
    [/usercollection\/daily_sleep\/doc1/, () => ({ json: { id: "doc1", day: "2026-10-02", score: 82 } })],
    [/usercollection\/(\w+)\?/, (url) => ({ json: { data: COLLECTIONS[/usercollection\/(\w+)\?/.exec(url)[1]] ?? [], next_token: null } })],
  ]);
}

function ouraSetup() {
  const ctx = createTestRepo();
  const fetch = ouraFetch();
  const oura = createOuraClient({ clientId: "cid", clientSecret: "secret", redirectUri: "https://api.example/v1/integrations/oura/callback", fetch, now: ctx.now });
  const vault = createTokenVault({ kms: createFakeKms(), keyId: "k" });
  const sent = [];
  const queue = { send: async (b) => { sent.push(b); } };
  const handler = createOuraHandler({
    repo: ctx.repo, vault, oura, queue, logger: silentLogger,
    getOuraSecret: async () => ({ clientSecret: "secret", webhookVerificationToken: "verify-me" }),
  });
  return { ...ctx, fetch, oura, vault, queue, sent, handler };
}

test("Oura OAuth: authorize stores state, callback exchanges code, encrypts tokens, maps GSI2, single-use state", async () => {
  const s = ouraSetup();
  const auth = parse(await s.handler(apiEvent({ method: "POST", path: "/v1/integrations/oura/authorize" })));
  const url = new URL(auth.body.authorizeUrl);
  assert.equal(url.origin + url.pathname, "https://cloud.ouraring.com/oauth/authorize");
  const state = url.searchParams.get("state");
  assert.equal(url.searchParams.get("response_type"), "code");
  const stored = await s.repo.get(oauthStateKey(state));
  assert.equal(stored.sub, SUB);
  assert.ok(stored.expiresAt <= s.now() / 1000 + 600);

  const cb = await s.handler(apiEvent({ path: "/v1/integrations/oura/callback", query: { code: "c0de", state }, sub: null }));
  assert.equal(cb.statusCode, 302);
  assert.equal(cb.headers.location, "healthapp://oura/connected");
  const conn = await s.repo.get(connectionKey(SUB, "oura"));
  assert.equal(conn.status, "connected");
  assert.equal(conn.GSI2PK, "OURAUSER#oura-user-1");
  assert.ok(conn.tokenCiphertext && !conn.tokenCiphertext.includes("at-1"));
  assert.deepEqual(s.sent[0].kind, "backfill");

  const replay = await s.handler(apiEvent({ path: "/v1/integrations/oura/callback", query: { code: "c0de", state }, sub: null }));
  assert.match(replay.headers.location, /^healthapp:\/\/oura\/error\?reason=invalid_state/);

  const me = parse(await s.handler(apiEvent({ method: "POST", path: "/v1/integrations/oura/sync", body: { from: "2026-10-02", to: "2026-10-03" } })));
  assert.equal(me.status, 200);
  assert.equal(me.body.daysUpserted, 2);
  assert.equal(me.body.workoutsUpserted, 1);
  const day = await s.repo.get(dayKey(SUB, "2026-10-02", "oura"));
  assert.equal(day.metrics.sleepScore, 82);
  assert.equal(day.entityType, "dailyMetrics");
  const day3 = await s.repo.get(dayKey(SUB, "2026-10-03", "oura"));
  assert.equal(day3.metrics.steps, 4000, "second page followed via next_token");

  const del = await s.handler(apiEvent({ method: "DELETE", path: "/v1/integrations/oura" }));
  assert.equal(del.statusCode, 204);
  const revoked = await s.repo.get(connectionKey(SUB, "oura"));
  assert.equal(revoked.status, "revoked");
  assert.equal(revoked.tokenCiphertext, undefined);
  assert.equal(revoked.GSI2PK, undefined);
  assert.ok(s.fetch.calls.some((c) => c.url.includes("/oauth/revoke")));
});

test("Oura sync refreshes expired tokens and persists the rotated pair", async () => {
  const s = ouraSetup();
  await s.repo.putVersioned(SUB, connectionKey(SUB, "oura"), "connection", "oura", { provider: "oura", status: "connected" }, {
    extra: { tokenCiphertext: await s.vault.encrypt(SUB, { access_token: "old", refresh_token: "r0", expires_at: s.now() / 1000 - 10 }) },
  });
  await syncOuraForUser({ repo: s.repo, vault: s.vault, oura: s.oura, sub: SUB, from: "2026-10-02", to: "2026-10-02", now: s.now() });
  const conn = await s.repo.get(connectionKey(SUB, "oura"));
  const tokens = await s.vault.decrypt(SUB, conn.tokenCiphertext);
  assert.equal(tokens.access_token, "at-1");
  assert.equal(tokens.refresh_token, "rt-1");
  assert.ok(conn.lastSyncAt);
  const apiCalls = s.fetch.calls.filter((c) => c.url.includes("/v2/usercollection"));
  assert.ok(apiCalls.every((c) => c.init.headers.authorization === "Bearer at-1"));
});

test("webhook endpoint: verification challenge, signature check, enqueue; worker resolves user via GSI2", async () => {
  const s = ouraSetup();
  const ok = parse(await s.handler(apiEvent({ path: "/v1/webhooks/oura", query: { verification_token: "verify-me", challenge: "abc" }, sub: null })));
  assert.deepEqual(ok.body, { challenge: "abc" });
  assert.equal(parse(await s.handler(apiEvent({ path: "/v1/webhooks/oura", query: { verification_token: "nope", challenge: "abc" }, sub: null }))).status, 401);

  const body = JSON.stringify({ event_type: "update", data_type: "daily_sleep", object_id: "doc1", event_time: "2026-10-03T06:00:00Z", user_id: "oura-user-1" });
  const ts = String(Math.floor(s.now() / 1000));
  const sig = createHmac("sha256", "secret").update(ts + body).digest("hex");
  const bad = await s.handler(apiEvent({ method: "POST", path: "/v1/webhooks/oura", rawBody: body, headers: { "x-oura-signature": "00", "x-oura-timestamp": ts }, sub: null }));
  assert.equal(bad.statusCode, 401);
  const good = await s.handler(apiEvent({ method: "POST", path: "/v1/webhooks/oura", rawBody: body, headers: { "x-oura-signature": sig, "x-oura-timestamp": ts }, sub: null }));
  assert.equal(good.statusCode, 200);
  assert.equal(s.sent.length, 1);

  // connect the user so GSI2 resolves
  await s.repo.putVersioned(SUB, connectionKey(SUB, "oura"), "connection", "oura", { provider: "oura", status: "connected", ouraUserId: "oura-user-1" }, {
    extra: { GSI2PK: "OURAUSER#oura-user-1", GSI2SK: "CONNECTION", tokenCiphertext: await s.vault.encrypt(SUB, { access_token: "live", refresh_token: "r", expires_at: s.now() / 1000 + 3600 }) },
  });
  const worker = createWorker({ repo: s.repo, vault: s.vault, oura: s.oura, now: s.now, logger: silentLogger });
  const res = await worker({ Records: [{ messageId: "m1", body: JSON.stringify(s.sent[0]) }, { messageId: "m2", body: "not json" }] });
  assert.deepEqual(res.batchItemFailures, [{ itemIdentifier: "m2" }]);
  assert.ok(s.fetch.calls.some((c) => c.url.includes("usercollection/daily_sleep/doc1")), "changed document fetched");
  assert.equal((await s.repo.get(dayKey(SUB, "2026-10-02", "oura"))).metrics.sleepScore, 82);

  const sched = createScheduled({ repo: s.repo, vault: s.vault, oura: s.oura, now: s.now, logger: silentLogger });
  const summary = await sched();
  assert.equal(summary.users, 1);
  assert.equal(summary.synced, 1);
});
