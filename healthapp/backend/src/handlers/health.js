/**
 * healthFn — /v1/metrics*, /v1/body*, /v1/workouts*, /v1/notes*, /v1/cycle*, /v1/day/*, /v1/trends*
 */
import { ApiError, createRouter, json } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { bodyKey, cycleKey, dailyMetricsId, dayKey, noteKey, profileKey, skRange, workoutKey } from "../lib/keys.js";
import { toPublic } from "../lib/db.js";
import { bodySchema, cycleSchema, dailyMetricsSchema, noteSchema, workoutSchema } from "../lib/schemas.js";
import { localDate } from "../lib/dates.js";
import { mergeDayItems } from "../services/merge.js";
import { trainingLoad } from "../services/stats.js";
import { computeCompare, computeTrend } from "../services/trends.js";
import { buildDaySummary } from "../services/daySummary.js";
import { createUserData } from "../services/userData.js";
import { dateWindow } from "./nutrition.js";
import * as d from "../lib/deps.js";

const dateParam = (value) => validate(v.date(), value, "date");

/**
 * @param {{ repo: import("../lib/db.js").Repository, logger?: any }} deps
 */
export function createHandler(deps) {
  const { repo } = deps;
  const logger = deps.logger ?? d.logger;
  const profileOf = async (sub) => toPublic(await repo.get(profileKey(sub))) ?? {};
  const todayFor = (profile) => localDate(repo.now(), profile.timezone ?? "UTC");

  /** Upsert a batch of system-derived items (idempotent by key). */
  async function upsertAll(sub, rows, build) {
    let upserted = 0;
    for (const row of rows) {
      const { key, entityType, id, attrs } = build(row);
      await repo.putVersioned(sub, key, entityType, id, attrs);
      upserted++;
    }
    return upserted;
  }

  return createRouter([
    {
      method: "POST", path: "/v1/metrics/daily",
      handler: async ({ sub, body }) => {
        const { days } = validate(v.object({ days: v.array(dailyMetricsSchema, { min: 1, max: 31 }) }), body ?? {});
        const upserted = await upsertAll(sub, days, (day) => ({
          key: dayKey(sub, day.date, day.source), entityType: "dailyMetrics", id: dailyMetricsId(day.date, day.source), attrs: day,
        }));
        return json(200, { upserted });
      },
    },
    {
      method: "GET", path: "/v1/metrics/daily",
      handler: async (req) => {
        const { from, to } = dateWindow(req, 366);
        const profile = await profileOf(req.sub);
        const items = await repo.queryRange(skRange(req.sub, "DAY", from, to));
        const days = mergeDayItems(items, profile.sourcePrecedence).map(({ date, merged, bySource, provenance }) => ({ date, merged, bySource, provenance }));
        return json(200, { days });
      },
    },
    {
      method: "POST", path: "/v1/body",
      handler: async ({ sub, body }) => {
        const { measurements } = validate(v.object({ measurements: v.array(bodySchema, { min: 1, max: 100 }) }), body ?? {});
        const upserted = await upsertAll(sub, measurements, (m) => ({ key: bodyKey(sub, m.measuredAt, m.id), entityType: "body", id: m.id, attrs: m }));
        return json(200, { upserted });
      },
    },
    {
      method: "GET", path: "/v1/body",
      handler: async (req) => {
        const { from, to } = dateWindow(req, 366);
        const items = await repo.queryRange(skRange(req.sub, "BODY", from, to));
        return json(200, { measurements: items.map(toPublic) });
      },
    },
    {
      method: "POST", path: "/v1/workouts",
      handler: async ({ sub, body }) => {
        const { workouts } = validate(v.object({ workouts: v.array(workoutSchema, { min: 1, max: 100 }) }), body ?? {});
        const profile = await profileOf(sub);
        const age = profile.birthYear ? new Date(repo.now()).getUTCFullYear() - profile.birthYear : undefined;
        const upserted = await upsertAll(sub, workouts, (w) => {
          if (w.end < w.start) throw new ApiError("VALIDATION_ERROR", "workout end must be after start", { details: { id: w.id } });
          const { load, estimated } = trainingLoad(w, { age, sex: profile.sex });
          return { key: workoutKey(sub, w.start, w.id), entityType: "workout", id: w.id, attrs: { ...w, load, loadEstimated: estimated } };
        });
        return json(200, { upserted });
      },
    },
    {
      method: "GET", path: "/v1/workouts",
      handler: async (req) => {
        const { from, to } = dateWindow(req, 366);
        const items = await repo.queryRange(skRange(req.sub, "WORKOUT", from, to));
        return json(200, { workouts: items.map(toPublic) });
      },
    },
    {
      method: "PUT", path: "/v1/notes/{date}",
      handler: async ({ sub, params, body }) => {
        const date = dateParam(params.date);
        const note = validate(noteSchema, body ?? {});
        const saved = await repo.putVersioned(sub, noteKey(sub, date), "note", date, { ...note, date });
        return json(200, { note: toPublic(saved) });
      },
    },
    {
      method: "PUT", path: "/v1/cycle/{date}",
      handler: async ({ sub, params, body }) => {
        const date = dateParam(params.date);
        const profile = await profileOf(sub);
        if (!profile.cycleTrackingEnabled) throw new ApiError("FORBIDDEN", "Cycle tracking is not enabled");
        const entry = validate(cycleSchema, body ?? {});
        const saved = await repo.putVersioned(sub, cycleKey(sub, date), "cycle", date, { ...entry, date });
        return json(200, { entry: toPublic(saved) });
      },
    },
    {
      method: "GET", path: "/v1/day/{date}",
      handler: async ({ sub, params }) => {
        const date = dateParam(params.date);
        const summary = await buildDaySummary({ data: createUserData(repo, sub), date, now: repo.now() });
        return json(200, summary);
      },
    },
    {
      method: "GET", path: "/v1/trends/compare",
      handler: async ({ sub, query }) => {
        const data = createUserData(repo, sub);
        const profile = await data.profile();
        const lagDays = query.lagDays === undefined ? 0 : validate(v.number({ int: true, min: 0, max: 1 }), query.lagDays, "lagDays");
        const result = await computeCompare({
          data, profile, x: validate(v.string(), query.x, "x"), y: validate(v.string(), query.y, "y"),
          range: query.range ?? "30d", lagDays, today: todayFor(profile),
        });
        return json(200, result);
      },
    },
    {
      method: "GET", path: "/v1/trends/{metric}",
      handler: async ({ sub, params, query }) => {
        const data = createUserData(repo, sub);
        const profile = await data.profile();
        const result = await computeTrend({ data, profile, metric: params.metric, range: query.range ?? "30d", agg: query.agg ?? "day", today: todayFor(profile) });
        return json(200, result);
      },
    },
  ], { logger });
}

export const handler = d.lazyHandler(createHandler, async () => ({ repo: await d.repository() }));
