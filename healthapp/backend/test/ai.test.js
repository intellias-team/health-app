import { test } from "node:test";
import assert from "node:assert/strict";
import { analyzeMealPhoto, assignScaleReadings, MEAL_ANALYSIS_SCHEMA, normalizeRange } from "../src/services/ai/mealRecognition.js";
import { parseVoiceLog, toGrams } from "../src/services/ai/voiceParse.js";
import { COACH_TOOLS, runCoachTurn } from "../src/services/ai/coach.js";
import { ClaudeError, createMessage } from "../src/services/ai/claude.js";
import { createUserData } from "../src/services/userData.js";
import { createHandler as createAiHandler } from "../src/handlers/ai.js";
import { silentLogger } from "../src/lib/logger.js";
import { analysisKey, chatPrefix, dayKey, mealKey, profileKey } from "../src/lib/keys.js";
import {
  apiEvent, BREAD, CHICKEN, COTTAGE, createFakeClaude, createFakeMedia, createFakeUsda, createTestRepo, EGG, JPEG_BYTES, parse, RICE, BROCCOLI, SUB, textResponse,
} from "./helpers/fakes.js";

const PHOTO = `users/${SUB}/meals/7b0e4c1a-0000-4000-8000-000000000001.jpg`;
const jsonResponse = (obj) => textResponse(JSON.stringify(obj));
const modelItems = {
  items: [
    { name: "white rice, cooked", usdaSearchQuery: "rice white cooked", estimatedGrams: 180, gramsLow: 130, gramsHigh: 240, confidence: 0.78, portionCues: ["fills half a dinner plate"], cookingMethod: "boiled", alternatives: ["jasmine rice"] },
    { name: "grilled chicken breast", usdaSearchQuery: "chicken breast grilled", estimatedGrams: 120, gramsLow: 90, gramsHigh: 160, confidence: 0.85, portionCues: ["palm-sized"], cookingMethod: "grilled", alternatives: [] },
    { name: "broccoli", usdaSearchQuery: "broccoli steamed", estimatedGrams: 80, gramsLow: 75, gramsHigh: 82, confidence: 0.9, portionCues: [], cookingMethod: "steamed", alternatives: [] },
  ],
  questions: ["Was the chicken cooked with oil or butter?"],
};

function aiDeps(responses, extra = {}) {
  const ctx = createTestRepo();
  const media = createFakeMedia({ [PHOTO]: JPEG_BYTES });
  const claude = createFakeClaude(responses);
  const usda = createFakeUsda([RICE, CHICKEN, BROCCOLI, EGG, BREAD, COTTAGE]);
  return { ...ctx, media, claude, usda, ...extra };
}

test("meal schema asks only for identification + grams (no calorie fields)", () => {
  const itemProps = Object.keys(MEAL_ANALYSIS_SCHEMA.properties.items.items.properties);
  assert.ok(!itemProps.some((p) => /kcal|calor|nutri|protein|fat|carb/i.test(p)));
  assert.equal(MEAL_ANALYSIS_SCHEMA.additionalProperties, false);
  assert.equal(MEAL_ANALYSIS_SCHEMA.properties.items.items.additionalProperties, false);
});

test("meal analysis without scale: nutrients from DB × grams, honest ranges, request shape", async () => {
  // The model tries to sneak in calories; they must be ignored.
  const sneaky = structuredClone(modelItems);
  sneaky.items[0].kcal = 9999;
  const deps = aiDeps([jsonResponse(sneaky)]);
  const out = await analyzeMealPhoto({ sub: SUB, input: { photoKey: PHOTO, mealCategory: "lunch" }, deps: { ...deps, newId: () => "an1" } });

  const rice = out.items[0];
  assert.deepEqual(rice.foodRef, { db: "usda", id: "169757" });
  assert.equal(rice.nutrients.kcal, 234, "130 kcal/100 g × 180 g");
  assert.deepEqual(rice.range, { kcalLow: 169, kcalHigh: 312 }, "kcal range from model gramsLow/High 130–240");
  assert.equal(rice.weightSource, "estimated");
  const broccoli = out.items[2];
  assert.ok(broccoli.gramsLow <= 68 && broccoli.gramsHigh >= 92, "narrow model range widened to ±15 %");
  assert.equal(out.isEstimate, true);
  assert.equal(out.totals.kcal, 234 + 198 + 28);
  assert.deepEqual(out.questions, ["Was the chicken cooked with oil or butter?"]);
  assert.equal(out.model, "anthropic.claude-opus-5-5");

  const req = deps.claude.requests[0];
  assert.deepEqual(req.thinking, { type: "adaptive" });
  assert.equal(req.output_config.effort, "medium");
  assert.equal(req.output_config.format.type, "json_schema");
  assert.equal(req.messages.length, 1, "no assistant prefill");
  assert.equal(req.messages[0].content[0].type, "image", "image block before text");
  assert.equal(req.messages[0].content[0].source.media_type, "image/jpeg");
  assert.equal(req.messages[0].content[1].type, "text");
  assert.match(req.system, /Never claim exactness/);
  assert.ok(!JSON.stringify(req).includes("budget_tokens"));

  const stored = await deps.repo.get(analysisKey(SUB, "an1"));
  assert.equal(stored.status, "complete");
  assert.ok(stored.expiresAt > deps.now() / 1000 + 6 * 86400);
});

test("meal analysis with scale readings: ranges collapse, weightSource scale, isEstimate false when all weighed", async () => {
  const deps = aiDeps([jsonResponse(modelItems)]);
  const out = await analyzeMealPhoto({
    sub: SUB,
    input: { photoKey: PHOTO, scaleReadings: [{ grams: 142, label: "chicken" }, { grams: 205 }, { grams: 95 }] },
    deps,
  });
  const [rice, chicken, broccoli] = out.items;
  assert.equal(chicken.grams, 142);
  assert.equal(chicken.weightSource, "scale");
  assert.equal(chicken.gramsLow, chicken.gramsHigh);
  assert.equal(chicken.nutrients.kcal, 234, "165 kcal/100 g × 142 g");
  assert.deepEqual(chicken.range, { kcalLow: 234, kcalHigh: 234 });
  assert.equal(rice.grams, 205, "largest estimate gets the closest remaining reading");
  assert.equal(broccoli.grams, 95);
  assert.equal(out.isEstimate, false);
  assert.equal(out.totalsRange.kcalLow, out.totalsRange.kcalHigh);
  assert.match(deps.claude.requests[0].messages[0].content[1].text, /142 g \(chicken\)/);
});

test("assignScaleReadings: single reading ↔ single item; partial weighing stays an estimate", () => {
  const one = assignScaleReadings([{ name: "soup", grams: 300, gramsLow: 250, gramsHigh: 400 }], [{ grams: 350 }]);
  assert.deepEqual([one[0].grams, one[0].gramsLow, one[0].gramsHigh, one[0].weightSource], [350, 350, 350, "scale"]);
  const partial = assignScaleReadings(
    [{ name: "pasta", grams: 200, gramsLow: 150, gramsHigh: 260 }, { name: "salad", grams: 60, gramsLow: 40, gramsHigh: 90 }],
    [{ grams: 70, label: "salad bowl" }],
  );
  assert.equal(partial[1].weightSource, "scale");
  assert.equal(partial[0].weightSource, "estimated");
  assert.deepEqual(normalizeRange({ estimatedGrams: 100, gramsLow: 99, gramsHigh: 101 }), { grams: 100, gramsLow: 85, gramsHigh: 115 });
});

test("meal analysis rejects other users' photos and non-JPEG bytes before calling the model", async () => {
  const deps = aiDeps([]);
  await assert.rejects(analyzeMealPhoto({ sub: SUB, input: { photoKey: "users/someone-else/meals/x.jpg" }, deps }), { code: "FORBIDDEN" });
  deps.media.store.set(PHOTO, Buffer.from("GIF89a....."));
  await assert.rejects(analyzeMealPhoto({ sub: SUB, input: { photoKey: PHOTO }, deps }), { code: "VALIDATION_ERROR" });
  assert.equal(deps.claude.requests.length, 0);
});

test("refusal and max_tokens become typed errors; handler maps refusal → 422 and max_tokens → 502", async () => {
  const refusal = { stop_reason: "refusal", stop_details: { type: "refusal", category: "bio", explanation: "x" }, content: [] };
  await assert.rejects(createMessage(createFakeClaude([refusal]), { messages: [] }), (e) => e instanceof ClaudeError && e.kind === "refusal" && e.category === "bio" && e.status === 422);

  const deps = aiDeps([refusal, textResponse("{\"items\":[", "max_tokens")]);
  const h = createAiHandler({ ...deps, logger: silentLogger });
  const r1 = parse(await h(apiEvent({ method: "POST", path: "/v1/ai/meal-analysis", body: { photoKey: PHOTO } })));
  assert.equal(r1.status, 422);
  assert.equal(r1.body.error.code, "AI_REFUSED");
  const r2 = parse(await h(apiEvent({ method: "POST", path: "/v1/ai/meal-analysis", body: { photoKey: PHOTO } })));
  assert.equal(r2.status, 502);
  assert.equal(r2.body.error.code, "AI_INCOMPLETE");
});

test("AI routes are rate limited to 30/hour/user", async () => {
  const responses = Array.from({ length: 31 }, () => jsonResponse({ items: [] }));
  const deps = aiDeps(responses);
  const h = createAiHandler({ ...deps, logger: silentLogger });
  for (let i = 0; i < 30; i++) {
    const r = await h(apiEvent({ method: "POST", path: "/v1/ai/voice-parse", body: { transcript: "an apple" } }));
    assert.equal(r.statusCode, 200);
  }
  const limited = parse(await h(apiEvent({ method: "POST", path: "/v1/ai/voice-parse", body: { transcript: "an apple" } })));
  assert.equal(limited.status, 429);
  assert.ok(limited.headers["retry-after"]);
  deps.now.advance(3_600_000);
  assert.equal((await h(apiEvent({ method: "POST", path: "/v1/ai/voice-parse", body: { transcript: "an apple" } }))).statusCode, 200);
});

test("upload-url returns a caller-scoped key with retention tagging", async () => {
  const deps = aiDeps([]);
  const h = createAiHandler({ ...deps, logger: silentLogger });
  const r = parse(await h(apiEvent({ method: "POST", path: "/v1/photos/upload-url", body: { mealId: "7b0e4c1a-0000-4000-8000-000000000002", contentType: "image/jpeg" } })));
  assert.equal(r.status, 200);
  assert.equal(r.body.photoKey, `users/${SUB}/meals/7b0e4c1a-0000-4000-8000-000000000002.jpg`);
  assert.equal(r.body.expiresIn, 300);
  assert.equal(r.body.requiredHeaders["x-amz-tagging"], "retention=meal-30d");
  const png = parse(await h(apiEvent({ method: "POST", path: "/v1/photos/upload-url", body: { mealId: "7b0e4c1a-0000-4000-8000-000000000002", contentType: "image/png" } })));
  assert.equal(png.status, 400);
});

// ── voice ───────────────────────────────────────────────────────────────────
test("toGrams: mass units exact, household units via USDA portions or built-in table", () => {
  assert.deepEqual(toGrams({ quantity: 150, unit: "g", food: "rice" }), { grams: 150, method: "mass", exact: true });
  assert.equal(toGrams({ quantity: 2, unit: "oz", food: "cheese" }).grams, 56.7);
  assert.equal(toGrams({ quantity: 2, unit: "eggs", food: "egg" }).grams, 100);
  assert.equal(toGrams({ quantity: 2, unit: "slices", food: "whole wheat bread" }).grams, 60);
  assert.equal(toGrams({ quantity: 1, unit: "cup", food: "cottage cheese" }).grams, 226);
  assert.deepEqual(toGrams({ quantity: 0.5, unit: "cup", food: "cottage cheese" }, [{ label: "cup, large curd", gramsPerUnit: 210 }]), { grams: 105, method: "usda_portion", exact: false });
});

test("voice parse: structured items → grams → nutrients from DB", async () => {
  const parsed = { items: [
    { quantity: 2, unit: "egg", food: "eggs", usdaSearchQuery: "egg whole cooked", preparation: "scrambled" },
    { quantity: 1, unit: "slice", food: "whole wheat toast", usdaSearchQuery: "bread whole wheat", preparation: "" },
    { quantity: 1, unit: "cup", food: "cottage cheese", usdaSearchQuery: "cottage cheese", preparation: "" },
  ] };
  const deps = aiDeps([jsonResponse(parsed)]);
  const out = await parseVoiceLog({ input: { transcript: "two scrambled eggs, a slice of toast and a cup of cottage cheese" }, deps });
  assert.deepEqual(out.items.map((i) => i.grams), [100, 30, 226]);
  assert.equal(out.items[0].nutrients.kcal, 155);
  assert.equal(out.items[1].nutrients.kcal, 76);
  assert.equal(out.items[2].nutrients.proteinG, 23.7);
  assert.equal(out.items[0].weightSource, "estimated");
  assert.ok(out.items[0].range.kcalLow < out.items[0].range.kcalHigh);
  const req = deps.claude.requests[0];
  assert.equal(req.output_config.effort, "low");
  assert.equal(req.output_config.format.schema.additionalProperties, false);
});

// ── coach ───────────────────────────────────────────────────────────────────
test("coach: manual tool loop (tool_use → tool_results in one message → text), append-only history", async () => {
  const deps = aiDeps([]);
  const { repo } = deps;
  await repo.putVersioned(SUB, profileKey(SUB), "profile", "profile", { timezone: "UTC" });
  await repo.putVersioned(SUB, mealKey(SUB, "2026-10-03", "m1"), "meal", "m1", {
    date: "2026-10-03", category: "lunch", loggedAt: "2026-10-03T12:00:00Z", totals: { kcal: 700, sodiumMg: 1900 },
    items: [{ name: "Ramen", grams: 500, nutrients: { kcal: 600, sodiumMg: 1800 } }, { name: "Egg", grams: 50, nutrients: { kcal: 100, sodiumMg: 100 } }],
  });
  await repo.putVersioned(SUB, dayKey(SUB, "2026-10-03", "oura"), "dailyMetrics", "2026-10-03:oura", { date: "2026-10-03", source: "oura", metrics: { sleepScore: 81 } });

  const toolTurn = {
    stop_reason: "tool_use", stop_details: null,
    content: [
      { type: "thinking", thinking: "", signature: "s1" },
      { type: "tool_use", id: "tu1", name: "get_meals", input: { from: "2026-10-03", to: "2026-10-03" } },
      { type: "tool_use", id: "tu2", name: "get_daily_metrics", input: { from: "2026-10-03", to: "2026-09-01" } },
    ],
  };
  const claude = createFakeClaude([toolTurn, textResponse("Ramen contributed most of today's sodium (1800 mg of 1900 mg, meals on 3 Oct).")]);
  const out = await runCoachTurn({ sub: SUB, input: { conversationId: "conv1", message: "Which foods contributed the most sodium today?" }, deps: { claude, repo, data: createUserData(repo, SUB), now: deps.now } });

  assert.match(out.reply, /Ramen/);
  assert.deepEqual(out.citations, [{ metric: "meals", from: "2026-10-03", to: "2026-10-03" }]);
  assert.match(out.disclaimer, /not medical advice/);

  assert.equal(claude.requests.length, 2);
  const first = claude.requests[0];
  assert.deepEqual(first.tool_choice, { type: "auto" });
  assert.ok(first.tools.every((t) => t.strict === true && t.input_schema.additionalProperties === false));
  assert.match(first.system, /correlation does not show causation/);
  assert.match(first.system, /Do not diagnose/);

  const second = claude.requests[1].messages;
  assert.deepEqual(second[1].content, toolTurn.content, "full assistant content appended verbatim");
  const results = second[2].content;
  assert.equal(second[2].role, "user");
  assert.equal(results.length, 2, "all tool_results in one user message");
  assert.equal(results[0].tool_use_id, "tu1");
  assert.match(results[0].content, /Ramen/);
  assert.match(results[0].content, /1800/);
  assert.equal(results[1].is_error, true, "invalid range reported as is_error");

  // History persisted and replayed unchanged next turn
  const stored = await repo.queryPrefix(chatPrefix(SUB, "conv1"));
  assert.equal(stored.length, 4);
  const claude2 = createFakeClaude([textResponse("Sleep score was 81.")]);
  await runCoachTurn({ sub: SUB, input: { conversationId: "conv1", message: "And my sleep?" }, deps: { claude: claude2, repo, data: createUserData(repo, SUB), now: deps.now } });
  const replay = claude2.requests[0].messages;
  assert.equal(replay.length, 5);
  assert.deepEqual(replay.slice(0, 3), claude.requests[1].messages, "earlier turns replayed byte-for-byte");
  assert.equal(replay[3].role, "assistant");
  assert.match(replay[3].content.find((b) => b.type === "text").text, /Ramen/);
  assert.match(replay[4].content[0].text, /And my sleep\?/);
});

test("coach stops after 6 iterations with a graceful reply", async () => {
  const deps = aiDeps([]);
  const loop = { stop_reason: "tool_use", content: [{ type: "tool_use", id: "t", name: "get_trend", input: { metric: "steps", range: "7d" } }] };
  const claude = createFakeClaude(Array.from({ length: 6 }, () => structuredClone(loop)));
  const out = await runCoachTurn({ sub: SUB, input: { conversationId: "c2", message: "hi" }, deps: { claude, repo: deps.repo, data: createUserData(deps.repo, SUB), now: deps.now } });
  assert.equal(claude.requests.length, 6);
  assert.match(out.reply, /couldn't finish/);
  assert.equal(COACH_TOOLS.length, 6);
});
