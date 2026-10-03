/**
 * syncFn — /v1/sync/push, /v1/sync/pull (offline-first, API §3.4)
 *
 * push: each change is applied with `attribute_not_exists(PK) OR version = :baseVersion`; on
 *       conflict the current server item is returned so the client can resolve and re-queue.
 * pull: change feed from GSI1 (`GSI1SK > cursor`), oldest first; cursor = last GSI1SK seen
 *       (opaque base64url to clients).
 */
import { ApiError, createRouter, json } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { dailyMetricsId, keyForEntity, profileKey } from "../lib/keys.js";
import { stripReserved, toPublic, VersionConflictError } from "../lib/db.js";
import {
  bodySchema, customFoodSchema, cycleSchema, dailyMetricsSchema, goalsSchema, noteSchema, profileSchema, recipeSchema, workoutSchema,
} from "../lib/schemas.js";
import { isDate } from "../lib/dates.js";
import { prepareMeal } from "./nutrition.js";
import * as d from "../lib/deps.js";

/** Client-writable entity types (connections/devices/analysis/chat are server-managed). */
const PUSHABLE = {
  profile: (sub, id, data) => ({ id: "profile", data: validate(profileSchema, data, "data") }),
  goals: (sub, id, data) => ({ id: "goals", data: validate(goalsSchema, data, "data") }),
  meal: (sub, id, data) => ({ id, data: prepareMeal(sub, { ...data, id }) }),
  dailyMetrics: (sub, id, data) => {
    const day = validate(dailyMetricsSchema, data, "data");
    return { id: dailyMetricsId(day.date, day.source), data: day };
  },
  body: (sub, id, data) => ({ id, data: validate(bodySchema, { ...data, id }, "data") }),
  workout: (sub, id, data) => ({ id, data: validate(workoutSchema, { ...data, id }, "data") }),
  customFood: (sub, id, data) => ({ id, data: validate(customFoodSchema, data, "data") }),
  recipe: (sub, id, data) => ({ id, data: validate(recipeSchema, data, "data") }),
  note: (sub, id, data) => ({ id, data: { ...validate(noteSchema, data, "data"), date: validate(v.date(), data.date ?? id, "data.date") } }),
  cycle: (sub, id, data) => ({ id, data: { ...validate(cycleSchema, data, "data"), date: validate(v.date(), data.date ?? id, "data.date") } }),
};

/** Fields needed to locate an item for deletes (date-keyed entities). */
const DELETE_KEY_FIELDS = {
  meal: v.object({ date: v.date() }),
  dailyMetrics: v.object({ date: v.date(), source: v.string({ enum: ["healthkit", "oura", "manual"] }) }),
  body: v.object({ measuredAt: v.timestamp() }),
  workout: v.object({ start: v.timestamp() }),
  note: v.object({ date: v.optional(v.date()) }),
  cycle: v.object({ date: v.optional(v.date()) }),
};

const changeSchema = v.object({
  entityType: v.string({ enum: Object.keys(PUSHABLE) }),
  id: v.id(64),
  op: v.string({ enum: ["upsert", "delete"] }),
  baseVersion: v.number({ int: true, min: 0 }),
  data: v.default(v.any({ maxBytes: 300_000 }), {}),
});

export const encodeCursor = (gsi1sk) => Buffer.from(gsi1sk, "utf8").toString("base64url");
export function decodeCursor(cursor) {
  if (!cursor) return "";
  const s = Buffer.from(String(cursor), "base64url").toString("utf8");
  if (!s.startsWith("UPD#")) throw new ApiError("VALIDATION_ERROR", "Invalid cursor");
  return s;
}

/**
 * @param {{ repo: import("../lib/db.js").Repository, logger?: any }} deps
 */
export function createHandler(deps) {
  const { repo } = deps;
  const logger = deps.logger ?? d.logger;

  /** Validate everything up front so a batch is either fully understood or rejected with 400. */
  function prepare(sub, change, index) {
    const c = validate(changeSchema, change, `changes[${index}]`);
    if (c.op === "delete") {
      const keyFields = DELETE_KEY_FIELDS[c.entityType] ? validate(DELETE_KEY_FIELDS[c.entityType], c.data ?? {}, `changes[${index}].data`) : {};
      const id = c.entityType === "dailyMetrics" ? dailyMetricsId(keyFields.date, keyFields.source) : c.id;
      if ((c.entityType === "note" || c.entityType === "cycle") && !isDate(keyFields.date ?? c.id)) {
        throw new ApiError("VALIDATION_ERROR", `changes[${index}].id must be a date for ${c.entityType}`);
      }
      return { ...c, id, key: keyForEntity(sub, c.entityType, c.id, keyFields) };
    }
    const { id, data } = PUSHABLE[c.entityType](sub, c.id, c.data ?? {});
    return { ...c, id, data, key: keyForEntity(sub, c.entityType, id, data) };
  }

  return createRouter([
    {
      method: "POST", path: "/v1/sync/push",
      handler: async ({ sub, body }) => {
        const { changes } = validate(v.object({ changes: v.array(v.any({ maxBytes: 400_000 }), { max: 100 }) }), body ?? {});
        const prepared = changes.map((c, i) => prepare(sub, c, i));
        const results = [];
        for (const c of prepared) {
          try {
            let item;
            if (c.op === "delete") {
              item = c.entityType === "profile" ? undefined : await repo.tombstone(sub, c.key, c.entityType, c.id, { expectedVersion: c.baseVersion });
            } else {
              const extra = c.entityType === "profile" ? await profileExtras(sub) : undefined;
              item = await repo.putVersioned(sub, c.key, c.entityType, c.id, stripReserved(c.data), { expectedVersion: c.baseVersion, extra });
            }
            results.push({ id: c.id, status: "applied", serverVersion: item?.version ?? c.baseVersion });
          } catch (err) {
            if (!(err instanceof VersionConflictError)) throw err;
            results.push({ id: c.id, status: "conflict", serverVersion: err.serverItem?.version ?? 0, serverItem: err.serverItem ? toPublic(err.serverItem) : null });
          }
        }
        logger.info("sync push", { changes: prepared.length, conflicts: results.filter((r) => r.status === "conflict").length });
        return json(200, { results });
      },
    },
    {
      method: "GET", path: "/v1/sync/pull",
      handler: async ({ sub, query }) => {
        const limit = query.limit ? validate(v.number({ int: true, min: 1, max: 200 }), query.limit, "limit") : 100;
        const since = decodeCursor(query.since);
        const { items, hasMore } = await repo.queryChanges(sub, since, limit);
        const changes = items.map((i) => ({ entityType: i.entityType, id: i.id, deleted: Boolean(i.deleted), version: i.version, updatedAt: i.updatedAt, data: toPublic(i) }));
        const cursor = items.length ? encodeCursor(items[items.length - 1].GSI1SK) : (query.since ?? "");
        return json(200, { changes, cursor, hasMore });
      },
    },
  ], { logger });

  /** Keep server-owned profile fields (createdAt) when the client pushes a profile snapshot. */
  async function profileExtras(sub) {
    const current = await repo.get(profileKey(sub));
    return current?.createdAt ? { createdAt: current.createdAt } : { createdAt: repo.iso() };
  }
}

export const handler = d.lazyHandler(createHandler, async () => ({ repo: await d.repository() }));
