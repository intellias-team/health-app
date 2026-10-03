/**
 * AI health coach (POST /v1/ai/coach) — manual tool-use loop over the caller's own data.
 *
 * - tools are `strict: true` with `additionalProperties: false`; `tool_choice` is `auto`
 * - at most 6 model calls per turn; all tool_results of a turn go back in ONE user message,
 *   failures as `is_error: true`
 * - history lives in CHAT# items and is append-only: every message (including the full
 *   `response.content` of assistant turns) is stored verbatim and replayed unchanged
 */
import { addDays, daysBetween, isDate, localDate } from "../../lib/dates.js";
import { chatKey, chatPrefix } from "../../lib/keys.js";
import { ttlAfterDays } from "../../lib/dates.js";
import { ApiError } from "../../lib/http.js";
import { computeCompare, computeTrend, rangeDays, TREND_METRICS } from "../trends.js";
import { createMessage, extractText } from "./claude.js";

export const MAX_ITERATIONS = 6;
export const MAX_HISTORY_MESSAGES = 120;
const MAX_RANGE_DAYS = 92;
const MAX_TOOL_RESULT_CHARS = 40_000;

export const COACH_DISCLAIMER =
  "General wellness information based on your own logged data — not medical advice. For symptoms or health concerns, talk to a qualified clinician.";

export const COACH_SYSTEM_PROMPT = `You are the health coach inside a personal health and nutrition tracking app. You help one person understand their own logged data: meals and nutrients, sleep, recovery, heart-rate variability, activity, workouts and body measurements.

How to work:
- Answer only about this user's own data, which you can read with the tools. Fetch data before making claims about it; don't guess numbers.
- In your answer, say which metrics and dates you looked at (for example "sleep score and HRV, 4–10 Oct").
- When two measures move together, describe it as an association and say explicitly that correlation does not show causation; mention the number of days behind it and that other factors could explain it.
- Do not diagnose, do not name or suggest medical conditions, and do not interpret results as signs of illness. If the user describes concerning symptoms (for example chest pain, fainting, severe or persistent fatigue, disordered eating), suggest they talk to a clinician.
- Never encourage extreme calorie deficits, skipping meals, or rapid weight loss. When intake is low relative to expenditure, talk neutrally about recovery and fueling; do not praise a deficit.
- If data is missing or sparse, say so plainly rather than filling gaps.
- Keep answers short, concrete and kind. Use the user's units where known.`;

const DATE_PROP = { type: "string", description: "yyyy-mm-dd" };
const RANGE_ENUM = ["7d", "30d", "90d", "1y"];

/** Tool definitions (strict). */
export const COACH_TOOLS = [
  {
    name: "get_daily_metrics",
    description: "Daily health metrics (merged across sources): steps, active/resting energy, sleep minutes and stages, sleep/readiness/activity scores, HRV, resting heart rate, temperature deviation, SpO2, water. Max 92 days.",
    strict: true,
    input_schema: { type: "object", additionalProperties: false, required: ["from", "to"], properties: { from: DATE_PROP, to: DATE_PROP } },
  },
  {
    name: "get_meals",
    description: "Logged meals with per-item foods, grams and nutrients (kcal, protein, carbs, fat, fiber, sugar, sodium) and meal totals. Use for questions like which foods contributed most of a nutrient. Max 92 days.",
    strict: true,
    input_schema: { type: "object", additionalProperties: false, required: ["from", "to"], properties: { from: DATE_PROP, to: DATE_PROP } },
  },
  {
    name: "get_trend",
    description: "Daily series and summary (avg, min, max, change) for one metric over a range ending today.",
    strict: true,
    input_schema: {
      type: "object", additionalProperties: false, required: ["metric", "range"],
      properties: { metric: { type: "string", enum: Object.keys(TREND_METRICS) }, range: { type: "string", enum: RANGE_ENUM } },
    },
  },
  {
    name: "compare_metrics",
    description: "Pairs two metrics by day and returns Pearson r with the number of paired days. lagDays=1 compares x on one day with y on the next day.",
    strict: true,
    input_schema: {
      type: "object", additionalProperties: false, required: ["x", "y", "range", "lagDays"],
      properties: {
        x: { type: "string", enum: Object.keys(TREND_METRICS) },
        y: { type: "string", enum: Object.keys(TREND_METRICS) },
        range: { type: "string", enum: RANGE_ENUM },
        lagDays: { type: "integer", enum: [0, 1] },
      },
    },
  },
  {
    name: "get_workouts",
    description: "Workouts with type, start, duration, energy, heart rate and training load. Max 92 days.",
    strict: true,
    input_schema: { type: "object", additionalProperties: false, required: ["from", "to"], properties: { from: DATE_PROP, to: DATE_PROP } },
  },
  {
    name: "get_body",
    description: "Body measurements (weight, body fat %, muscle mass, BMI, water %, etc.). Max 92 days.",
    strict: true,
    input_schema: { type: "object", additionalProperties: false, required: ["from", "to"], properties: { from: DATE_PROP, to: DATE_PROP } },
  },
];

function checkRange(from, to) {
  if (!isDate(from) || !isDate(to)) throw new Error("from/to must be yyyy-mm-dd dates");
  if (from > to) throw new Error("from must be on or before to");
  if (daysBetween(from, to) > MAX_RANGE_DAYS) throw new Error(`range too long (max ${MAX_RANGE_DAYS} days)`);
}

const pick = (obj, keys) => Object.fromEntries(keys.filter((k) => obj[k] !== undefined).map((k) => [k, obj[k]]));

/**
 * Tool implementations bound to the caller's data only.
 * @param {import("../userData.js").UserData} data
 * @param {{ today: string, profile: any }} ctx
 * @returns {Record<string, (input: any) => Promise<{ result: any, citations: { metric: string, from: string, to: string }[] }>>}
 */
export function createCoachTools(data, { today, profile }) {
  const tz = profile.timezone ?? "UTC";
  return {
    async get_daily_metrics({ from, to }) {
      checkRange(from, to);
      const days = await data.daily(from, to, profile.sourcePrecedence);
      return { result: days.map((d) => ({ date: d.date, ...d.merged, sources: d.provenance })), citations: [{ metric: "dailyMetrics", from, to }] };
    },
    async get_meals({ from, to }) {
      checkRange(from, to);
      const meals = await data.meals(from, to);
      return {
        result: meals.map((m) => ({
          date: m.date, category: m.category, loggedAt: m.loggedAt, isEstimate: m.isEstimate, totals: m.totals,
          items: (m.items ?? []).map((i) => pick(i, ["name", "grams", "weightSource", "nutrients"])),
        })),
        citations: [{ metric: "meals", from, to }],
      };
    },
    async get_trend({ metric, range }) {
      const t = await computeTrend({ data, metric, range, agg: rangeDays(range) > 90 ? "week" : "day", today, profile });
      return { result: t, citations: [{ metric, from: t.from, to: t.to }] };
    },
    async compare_metrics({ x, y, range, lagDays }) {
      const c = await computeCompare({ data, x, y, range, lagDays, today, profile });
      const from = addDays(today, -(rangeDays(range) - 1));
      return { result: c, citations: [{ metric: x, from, to: today }, { metric: y, from, to: today }] };
    },
    async get_workouts({ from, to }) {
      checkRange(from, to);
      const ws = (await data.workouts(from, to)).filter((w) => {
        const d = localDate(w.start, tz);
        return d >= from && d <= to;
      });
      return {
        result: ws.map((w) => pick(w, ["start", "end", "type", "source", "durationMin", "activeKcal", "avgHr", "maxHr", "distanceM", "load"])),
        citations: [{ metric: "workouts", from, to }],
      };
    },
    async get_body({ from, to }) {
      checkRange(from, to);
      const rows = (await data.body(from, to)).filter((b) => {
        const d = localDate(b.measuredAt, tz);
        return d >= from && d <= to;
      });
      return {
        result: rows.map((b) => pick(b, ["measuredAt", "source", "weightKg", "bodyFatPct", "leanMassKg", "muscleMassKg", "bmi", "visceralFat", "waterPct", "boneMassKg"])),
        citations: [{ metric: "body", from, to }],
      };
    },
  };
}

function serializeResult(result) {
  const s = JSON.stringify(result);
  return s.length > MAX_TOOL_RESULT_CHARS ? `${s.slice(0, MAX_TOOL_RESULT_CHARS)}… [truncated; ask for a shorter date range]` : s;
}

/**
 * Run one coach turn.
 * @param {{
 *   sub: string,
 *   input: { conversationId: string, message: string },
 *   deps: { claude: any, repo: import("../../lib/db.js").Repository, data: import("../userData.js").UserData, now?: () => number },
 * }} p
 * @returns {Promise<{ reply: string, citations: { metric: string, from: string, to: string }[], disclaimer: string }>}
 */
export async function runCoachTurn({ sub, input, deps }) {
  const now = deps.now ?? (() => Date.now());
  const { repo, data, claude } = deps;
  const profile = await data.profile();
  const today = localDate(now(), profile.timezone ?? "UTC");

  const stored = await repo.queryPrefix(chatPrefix(sub, input.conversationId));
  if (stored.length >= MAX_HISTORY_MESSAGES) {
    throw new ApiError("UNPROCESSABLE", "This conversation is too long; please start a new one", { details: { reason: "conversation_too_long" } });
  }
  const history = stored.map((item) => ({ role: item.role, content: item.content }));

  const userMessage = {
    role: "user",
    content: [{ type: "text", text: `(Today is ${today} in my timezone.)\n\n${input.message}` }],
  };
  const messages = [...history, userMessage];
  const appended = [userMessage];
  const tools = createCoachTools(data, { today, profile });
  const citations = new Map();

  let reply = "";
  for (let iteration = 0; iteration < MAX_ITERATIONS; iteration++) {
    const response = await createMessage(claude, {
      system: COACH_SYSTEM_PROMPT,
      tools: COACH_TOOLS,
      tool_choice: { type: "auto" },
      messages,
      output_config: { effort: "medium" },
    });
    const assistantMessage = { role: "assistant", content: response.content };
    messages.push(assistantMessage);
    appended.push(assistantMessage);

    if (response.stop_reason !== "tool_use") {
      reply = extractText(response);
      break;
    }

    const toolUses = response.content.filter((block) => block.type === "tool_use");
    const results = await Promise.all(toolUses.map(async (block) => {
      const impl = tools[block.name];
      try {
        if (!impl) throw new Error(`Unknown tool ${block.name}`);
        const { result, citations: cites } = await impl(block.input ?? {});
        for (const c of cites) citations.set(`${c.metric}|${c.from}|${c.to}`, c);
        return { type: "tool_result", tool_use_id: block.id, content: serializeResult(result) };
      } catch (err) {
        return { type: "tool_result", tool_use_id: block.id, content: `Error: ${err.message}`, is_error: true };
      }
    }));
    const toolResultMessage = { role: "user", content: results };
    messages.push(toolResultMessage);
    appended.push(toolResultMessage);
  }

  if (!reply) {
    reply = "I couldn't finish looking through your data for that question. Could you narrow it down, for example to a specific week or metric?";
  }

  // Append-only persistence (unique, increasing timestamps within the turn).
  const base = now();
  const expiresAt = ttlAfterDays(base, 90);
  for (const [i, msg] of appended.entries()) {
    const ts = new Date(base + i).toISOString();
    const isFinal = i === appended.length - 1 && msg.role === "assistant";
    await repo.putRaw({
      ...chatKey(sub, input.conversationId, ts),
      entityType: "chat",
      id: `${input.conversationId}:${ts}`,
      conversationId: input.conversationId,
      role: msg.role,
      content: msg.content,
      text: msg.role === "user" && i === 0 ? input.message : isFinal ? reply : undefined,
      citations: isFinal ? [...citations.values()] : undefined,
      createdAt: ts,
      expiresAt,
    });
  }

  return { reply, citations: [...citations.values()], disclaimer: COACH_DISCLAIMER };
}
