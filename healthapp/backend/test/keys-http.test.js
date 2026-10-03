import { test } from "node:test";
import assert from "node:assert/strict";
import * as keys from "../src/lib/keys.js";
import { ApiError, compilePath, createRouter, isFromTrustedOrigin, json } from "../src/lib/http.js";
import { silentLogger, hashSub, createLogger } from "../src/lib/logger.js";
import { apiEvent, parse, SUB } from "./helpers/fakes.js";

test("user key builders take sub and prefix USER#", () => {
  assert.deepEqual(keys.profileKey(SUB), { PK: `USER#${SUB}`, SK: "PROFILE" });
  assert.deepEqual(keys.mealKey(SUB, "2026-10-03", "abc"), { PK: `USER#${SUB}`, SK: "MEAL#2026-10-03#abc" });
  assert.equal(keys.dayKey(SUB, "2026-10-03", "oura").SK, "DAY#2026-10-03#oura");
  assert.equal(keys.bodyKey(SUB, "2026-10-03T07:00:00.000Z", "b1").SK, "BODY#2026-10-03T07:00:00.000Z#b1");
  assert.equal(keys.workoutKey(SUB, "2026-10-03T07:00:00.000Z", "w1").SK, "WORKOUT#2026-10-03T07:00:00.000Z#w1");
  assert.equal(keys.connectionKey(SUB, "bodyscale:abc").SK, "CONNECTION#bodyscale:abc");
  assert.equal(keys.chatKey(SUB, "c1", "2026-10-03T12:00:00.000Z").SK, "CHAT#c1#2026-10-03T12:00:00.000Z");
  assert.equal(keys.rateKey(SUB, "ai", "2026-10-03T12").SK, "RATE#ai#2026-10-03T12");
  assert.equal(keys.notificationLogKey(SUB, "meal_reminder", "2026-10-03").SK, "NOTIFLOG#meal_reminder#2026-10-03");
  assert.deepEqual(keys.systemRateKey("oura", "2026-10-03T12:05"), { PK: "SYSTEM#oura", SK: "RATE#2026-10-03T12:05" });
  assert.deepEqual(keys.oauthStateKey("st8"), { PK: "OAUTHSTATE#st8", SK: "STATE" });
  assert.deepEqual(keys.gsi1Keys(SUB, "2026-10-03T12:00:00.000Z", "meal", "m1"), { GSI1PK: `USER#${SUB}`, GSI1SK: "UPD#2026-10-03T12:00:00.000Z#meal#m1" });
  assert.deepEqual(keys.gsi2OuraKeys("ou1"), { GSI2PK: "OURAUSER#ou1", GSI2SK: "CONNECTION" });
});

test("key builders reject bad subs and '#' injection", () => {
  assert.throws(() => keys.profileKey(""), ApiError);
  assert.throws(() => keys.profileKey("a#b"), ApiError);
  assert.throws(() => keys.mealKey(SUB, "2026-10-03", "x#MEAL"), ApiError);
});

test("ranges, catalog keys and entity mapping", () => {
  const r = keys.skRange(SUB, "MEAL", "2026-10-01", "2026-10-03");
  assert.equal(r.from, "MEAL#2026-10-01");
  assert.ok("MEAL#2026-10-03#zzz" <= r.to);
  assert.equal(keys.gtinKey("012345678905").PK, "GTIN#00012345678905");
  assert.equal(keys.searchKey("  Chicken   Breast!! ").PK, "SEARCH#chicken breast");
  assert.equal(keys.keyForEntity(SUB, "meal", "m1", { date: "2026-10-03" }).SK, "MEAL#2026-10-03#m1");
  assert.equal(keys.keyForEntity(SUB, "note", "2026-10-03").SK, "NOTE#2026-10-03");
  assert.throws(() => keys.keyForEntity(SUB, "device", "d1"), ApiError);
});

test("router: missing sub on protected route → 401", async () => {
  const route = createRouter([{ method: "GET", path: "/v1/me", handler: async () => json(200, { ok: true }) }], { logger: silentLogger });
  const res = parse(await route(apiEvent({ path: "/v1/me", sub: null })));
  assert.equal(res.status, 401);
  assert.equal(res.body.error.code, "UNAUTHORIZED");
});

test("router: public routes skip auth, params decoded, 404 and error envelope", async () => {
  const route = createRouter([
    { method: "GET", path: "/v1/webhooks/oura", public: true, handler: async () => json(200, { ok: true }) },
    { method: "GET", path: "/v1/foods/{db}/{id}", handler: async (req) => json(200, req.params) },
    { method: "POST", path: "/v1/boom", handler: async () => { throw new Error("secret detail"); } },
    { method: "POST", path: "/v1/bad", handler: async () => { throw new ApiError("VALIDATION_ERROR", "nope", { details: { path: "x" } }); } },
  ], { logger: silentLogger });
  assert.equal(parse(await route(apiEvent({ path: "/v1/webhooks/oura", sub: null }))).status, 200);
  assert.deepEqual(parse(await route(apiEvent({ path: "/v1/foods/usda/123" }))).body, { db: "usda", id: "123" });
  assert.equal(parse(await route(apiEvent({ path: "/v1/nope" }))).status, 404);
  const boom = parse(await route(apiEvent({ method: "POST", path: "/v1/boom" })));
  assert.equal(boom.status, 500);
  assert.equal(boom.body.error.message, "Internal server error");
  const bad = parse(await route(apiEvent({ method: "POST", path: "/v1/bad" })));
  assert.deepEqual(bad.body, { error: { code: "VALIDATION_ERROR", message: "nope", details: { path: "x" } } });
  const badJson = parse(await route(apiEvent({ method: "POST", path: "/v1/bad", rawBody: "{oops" })));
  assert.equal(badJson.status, 400);
});

test("sub only comes from JWT claims, not headers", async () => {
  let seen;
  const route = createRouter([{ method: "GET", path: "/v1/me", handler: async (req) => { seen = req.sub; return json(200, {}); } }], { logger: silentLogger });
  const ev = apiEvent({ path: "/v1/me", headers: { "x-user-sub": "attacker" } });
  await route(ev);
  assert.equal(seen, SUB);
});

test("compilePath matches templates exactly", () => {
  const m = compilePath("/v1/meals/{id}");
  assert.deepEqual(m("/v1/meals/abc"), { id: "abc" });
  assert.equal(m("/v1/meals/abc/x"), null);
});

test("logger never writes bodies and hashes subs", () => {
  const lines = [];
  const log = createLogger({ write: (l) => lines.push(JSON.parse(l)) });
  log.info("x", { route: "POST /v1/ai/coach", body: "my secret", message: "hi", transcript: "t", sub: SUB, subHash: hashSub(SUB) });
  assert.equal(lines[0].body, undefined);
  assert.equal(lines[0].message, undefined);
  assert.equal(lines[0].transcript, undefined);
  assert.equal(lines[0].sub, undefined);
  assert.equal(lines[0].subHash.length, 16);
  assert.notEqual(lines[0].subHash, SUB);
});

test("router rejects requests that bypass CloudFront when an origin secret is set", async () => {
  const route = createRouter(
    [{ method: "GET", path: "/v1/health", public: true, handler: async () => json(200, { ok: true }) }],
    { logger: silentLogger, originSecret: "s3cret-value" },
  );
  assert.equal((await route(apiEvent({ path: "/v1/health", sub: null }))).statusCode, 403);
  assert.equal((await route(apiEvent({ path: "/v1/health", sub: null, headers: { "x-origin-verify": "wrong-value!" } }))).statusCode, 403);
  const ok = parse(await route(apiEvent({ path: "/v1/health", sub: null, headers: { "X-Origin-Verify": "s3cret-value" } })));
  assert.equal(ok.status, 200);
  assert.equal(isFromTrustedOrigin({}, undefined), true, "no secret configured → check disabled");
});
