import { test } from "node:test";
import assert from "node:assert/strict";
import { createHandler } from "../src/handlers/sync.js";
import { createHandler as createNutrition } from "../src/handlers/nutrition.js";
import { silentLogger } from "../src/lib/logger.js";
import { mealKey } from "../src/lib/keys.js";
import { apiEvent, createFakeMedia, createFakeUsda, createTestRepo, parse, SUB, OTHER_SUB } from "./helpers/fakes.js";

const MEAL_ID = "7b0e4c1a-0000-4000-8000-000000000001";
const meal = (overrides = {}) => ({
  date: "2026-10-03", loggedAt: "2026-10-03T12:41:00Z", category: "lunch", source: "manual",
  items: [{ id: "a1", name: "Rice", grams: 150, weightSource: "user", nutrients: { kcal: 195, proteinG: 4 } }],
  ...overrides,
});

function setup() {
  const ctx = createTestRepo();
  const sync = createHandler({ repo: ctx.repo, logger: silentLogger });
  return { ...ctx, sync };
}

test("sync push applies new items with baseVersion 0 and stamps version/GSI1", async () => {
  const { sync, repo } = setup();
  const res = parse(await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id: MEAL_ID, op: "upsert", baseVersion: 0, data: meal() }] } })));
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.results, [{ id: MEAL_ID, status: "applied", serverVersion: 1 }]);
  const stored = await repo.get(mealKey(SUB, "2026-10-03", MEAL_ID));
  assert.equal(stored.version, 1);
  assert.equal(stored.totals.kcal, 195, "server recomputes totals");
  assert.match(stored.GSI1SK, /^UPD#2026-10-03T12:00:00.000Z#meal#/);
});

test("sync push: stale baseVersion → conflict with server item (optimistic concurrency)", async () => {
  const { sync, now } = setup();
  const push = (baseVersion, data) => sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id: MEAL_ID, op: "upsert", baseVersion, data }] } }));
  await push(0, meal());
  now.advance(1000);
  const second = parse(await push(1, meal({ notes: "device A" })));
  assert.equal(second.body.results[0].status, "applied");
  assert.equal(second.body.results[0].serverVersion, 2);

  now.advance(1000);
  const stale = parse(await push(1, meal({ notes: "device B" })));
  const r = stale.body.results[0];
  assert.equal(r.status, "conflict");
  assert.equal(r.serverVersion, 2);
  assert.equal(r.serverItem.notes, "device A");
  assert.equal(r.serverItem.PK, undefined, "keys are not leaked");

  const create = parse(await push(0, meal({ notes: "again" })));
  assert.equal(create.body.results[0].status, "conflict", "baseVersion 0 on an existing item conflicts");
});

test("sync push deletes create tombstones with TTL and validates the whole batch", async () => {
  const { sync, repo } = setup();
  await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id: MEAL_ID, op: "upsert", baseVersion: 0, data: meal() }] } }));
  const del = parse(await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id: MEAL_ID, op: "delete", baseVersion: 1, data: { date: "2026-10-03" } }] } })));
  assert.equal(del.body.results[0].status, "applied");
  const tomb = await repo.get(mealKey(SUB, "2026-10-03", MEAL_ID), { includeDeleted: true });
  assert.equal(tomb.deleted, true);
  assert.equal(tomb.items, undefined, "content dropped");
  assert.ok(tomb.expiresAt > Date.parse("2026-12-31") / 1000, "expires ~90 days later");

  const bad = parse(await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "connection", id: "oura", op: "upsert", baseVersion: 0, data: {} }] } })));
  assert.equal(bad.status, 400);
});

test("sync pull pages through the change feed with an opaque cursor", async () => {
  const { sync, now } = setup();
  for (let i = 0; i < 5; i++) {
    now.advance(1000);
    const id = `00000000-0000-4000-8000-00000000000${i}`;
    await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id, op: "upsert", baseVersion: 0, data: meal() }] } }));
  }
  // another user's data must never appear
  await sync(apiEvent({ sub: OTHER_SUB, method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "note", id: "2026-10-03", op: "upsert", baseVersion: 0, data: { text: "x" } }] } }));

  const seen = [];
  let cursor = "";
  let pages = 0;
  for (;;) {
    const res = parse(await sync(apiEvent({ path: "/v1/sync/pull", query: { since: cursor || undefined, limit: "2" } })));
    assert.equal(res.status, 200);
    seen.push(...res.body.changes.map((c) => c.id));
    cursor = res.body.cursor;
    pages++;
    if (!res.body.hasMore) break;
  }
  assert.equal(pages, 3);
  assert.equal(seen.length, 5);
  assert.equal(new Set(seen).size, 5);

  // an update moves the item to the end of the feed after the cursor
  now.advance(1000);
  await sync(apiEvent({ method: "POST", path: "/v1/sync/push", body: { changes: [{ entityType: "meal", id: seen[0], op: "upsert", baseVersion: 1, data: meal({ notes: "edited" }) }] } }));
  const tail = parse(await sync(apiEvent({ path: "/v1/sync/pull", query: { since: cursor } })));
  assert.deepEqual(tail.body.changes.map((c) => [c.id, c.version, c.data.notes]), [[seen[0], 2, "edited"]]);
  assert.equal(tail.body.hasMore, false);

  const badCursor = parse(await sync(apiEvent({ path: "/v1/sync/pull", query: { since: "bm9wZQ" } })));
  assert.equal(badCursor.status, 400);
});

test("PUT /v1/meals honours version and DELETE tombstones + removes the photo", async () => {
  const { repo } = createTestRepo();
  const media = createFakeMedia({ [`users/${SUB}/meals/${MEAL_ID}.jpg`]: Buffer.from("x") });
  const h = createNutrition({ repo, media, usda: createFakeUsda([]), logger: silentLogger });
  const put = (body) => h(apiEvent({ method: "PUT", path: `/v1/meals/${MEAL_ID}`, body }));
  const first = parse(await put(meal({ photoKey: `users/${SUB}/meals/${MEAL_ID}.jpg`, photoPinned: true })));
  assert.equal(first.status, 200);
  assert.equal(first.body.meal.version, 1);
  assert.deepEqual(media.tags.get(`users/${SUB}/meals/${MEAL_ID}.jpg`), { pinned: "true" });
  assert.equal(parse(await put({ ...meal(), version: 0 })).status, 409);
  assert.equal(parse(await put({ ...meal({ photoKey: `users/${SUB}/meals/${MEAL_ID}.jpg` }), version: 1 })).body.meal.version, 2);
  const foreign = parse(await put(meal({ photoKey: `users/${OTHER_SUB}/meals/${MEAL_ID}.jpg` })));
  assert.equal(foreign.status, 403);

  const del = await h(apiEvent({ method: "DELETE", path: `/v1/meals/${MEAL_ID}` }));
  assert.equal(del.statusCode, 204);
  assert.equal(media.store.size, 0);
  const list = parse(await h(apiEvent({ path: "/v1/meals", query: { from: "2026-10-01", to: "2026-10-05" } })));
  assert.deepEqual(list.body.meals, []);
});
