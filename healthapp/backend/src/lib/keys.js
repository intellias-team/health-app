/**
 * DynamoDB key builders (schema doc §2.2 / §2.3).
 *
 * Every user-scoped builder takes `sub` and prefixes `USER#` — this is how the "LeadingKeys"
 * isolation rule (API §3.5) is enforced in code: no handler can construct a key for another user.
 */
import { ApiError } from "./http.js";

const SUB_RE = /^[A-Za-z0-9-]{1,128}$/;
const SEGMENT_RE = /^[^#\s]{1,200}$/;

/** @param {string} sub */
function assertSub(sub) {
  if (typeof sub !== "string" || !SUB_RE.test(sub)) throw new ApiError("UNAUTHORIZED", "Invalid subject");
  return sub;
}

/** Key segments must not contain `#` (would allow escaping into another key range). */
function seg(value, name) {
  const s = String(value ?? "");
  if (!SEGMENT_RE.test(s)) throw new ApiError("VALIDATION_ERROR", `Invalid ${name}`, { details: { field: name } });
  return s;
}

/** @param {string} sub */
export const userPk = (sub) => `USER#${assertSub(sub)}`;

/** @typedef {{ PK: string, SK: string }} Key */

/** @param {string} sub @returns {Key} */
export const profileKey = (sub) => ({ PK: userPk(sub), SK: "PROFILE" });
/** @param {string} sub @returns {Key} */
export const goalsKey = (sub) => ({ PK: userPk(sub), SK: "GOALS" });
/** @param {string} sub @param {string} provider @returns {Key} */
export const connectionKey = (sub, provider) => ({ PK: userPk(sub), SK: `CONNECTION#${seg(provider, "provider")}` });
/** @param {string} sub @param {string} date @param {string} mealId @returns {Key} */
export const mealKey = (sub, date, mealId) => ({ PK: userPk(sub), SK: `MEAL#${seg(date, "date")}#${seg(mealId, "id")}` });
/** @param {string} sub @param {string} date @param {string} source @returns {Key} */
export const dayKey = (sub, date, source) => ({ PK: userPk(sub), SK: `DAY#${seg(date, "date")}#${seg(source, "source")}` });
/** @param {string} sub @param {string} measuredAt ISO @param {string} id @returns {Key} */
export const bodyKey = (sub, measuredAt, id) => ({ PK: userPk(sub), SK: `BODY#${seg(measuredAt, "measuredAt")}#${seg(id, "id")}` });
/** @param {string} sub @param {string} start ISO @param {string} id @returns {Key} */
export const workoutKey = (sub, start, id) => ({ PK: userPk(sub), SK: `WORKOUT#${seg(start, "start")}#${seg(id, "id")}` });
/** @param {string} sub @param {string} id @returns {Key} */
export const customFoodKey = (sub, id) => ({ PK: userPk(sub), SK: `FOOD#${seg(id, "id")}` });
/** @param {string} sub @param {string} id @returns {Key} */
export const recipeKey = (sub, id) => ({ PK: userPk(sub), SK: `RECIPE#${seg(id, "id")}` });
/** @param {string} sub @param {string} date @returns {Key} */
export const noteKey = (sub, date) => ({ PK: userPk(sub), SK: `NOTE#${seg(date, "date")}` });
/** @param {string} sub @param {string} date @returns {Key} */
export const cycleKey = (sub, date) => ({ PK: userPk(sub), SK: `CYCLE#${seg(date, "date")}` });
/** @param {string} sub @param {string} id @returns {Key} */
export const deviceKey = (sub, id) => ({ PK: userPk(sub), SK: `DEVICE#${seg(id, "id")}` });
/** @param {string} sub @param {string} id @returns {Key} */
export const analysisKey = (sub, id) => ({ PK: userPk(sub), SK: `ANALYSIS#${seg(id, "id")}` });
/** @param {string} sub @param {string} conversationId @param {string} ts ISO @returns {Key} */
export const chatKey = (sub, conversationId, ts) => ({ PK: userPk(sub), SK: `CHAT#${seg(conversationId, "conversationId")}#${seg(ts, "ts")}` });
/** Per-user fixed-window counter (not syncable). */
export const rateKey = (sub, bucket, window) => ({ PK: userPk(sub), SK: `RATE#${seg(bucket, "bucket")}#${seg(window, "window")}` });
/** Notification de-duplication marker `NOTIFLOG#<kind>#<yyyy-mm-dd>` (not syncable). */
export const notificationLogKey = (sub, kind, date) => ({ PK: userPk(sub), SK: `NOTIFLOG#${seg(kind, "kind")}#${seg(date, "date")}` });
/** App-wide (not per-user) rate window, e.g. the shared Oura client quota: `SYSTEM#oura` / `RATE#<window>`. */
export const systemRateKey = (system, window) => ({ PK: `SYSTEM#${seg(system, "system")}`, SK: `RATE#${seg(window, "window")}` });
/** OAuth state (not user-partitioned: looked up by state on the public callback). */
export const oauthStateKey = (state) => ({ PK: `OAUTHSTATE#${seg(state, "state")}`, SK: "STATE" });

/**
 * Sort-key range for a prefix with date/timestamp bounds (inclusive).
 * @param {string} sub @param {string} prefix e.g. "MEAL" @param {string} from @param {string} to
 */
export function skRange(sub, prefix, from, to) {
  return { PK: userPk(sub), from: `${prefix}#${seg(from, "from")}`, to: `${prefix}#${seg(to, "to")}￿` };
}

/** Sort-key prefix for begins_with queries. */
export function skPrefix(sub, prefix) {
  return { PK: userPk(sub), prefix: `${prefix}#` };
}

/** Prefix of all messages of a conversation. */
export const chatPrefix = (sub, conversationId) => ({ PK: userPk(sub), prefix: `CHAT#${seg(conversationId, "conversationId")}#` });

// ── GSIs ────────────────────────────────────────────────────────────────────────────────────

/**
 * GSI1 change-feed keys (schema §2.2).
 * @param {string} sub @param {string} updatedAt @param {string} entityType @param {string} id
 */
export function gsi1Keys(sub, updatedAt, entityType, id) {
  return { GSI1PK: userPk(sub), GSI1SK: `UPD#${updatedAt}#${entityType}#${seg(id, "id")}` };
}

/** GSI2 Oura-user → connection mapping (sparse). */
export const gsi2OuraKeys = (ouraUserId) => ({ GSI2PK: `OURAUSER#${seg(ouraUserId, "ouraUserId")}`, GSI2SK: "CONNECTION" });

/**
 * GSI2 push-device index (sparse; additive use of GSI2 so the 15-minute notification job can
 * enumerate users with registered devices without scanning the base table).
 */
export const gsi2DeviceKeys = (sub, deviceId) => ({ GSI2PK: `PUSHDEVICE#${assertSub(sub)}`, GSI2SK: `DEVICE#${seg(deviceId, "id")}` });

// ── Food catalog table (§2.3) ───────────────────────────────────────────────────────────────

/** @param {string|number} fdcId */
export const fdcKey = (fdcId) => ({ PK: `FDC#${seg(fdcId, "fdcId")}`, SK: "FOOD" });

/** Normalise any UPC/EAN/GTIN to GTIN-14 (digits only, left-padded). */
export function normalizeGtin(code) {
  const digits = String(code ?? "").replace(/\D/g, "");
  if (digits.length < 8 || digits.length > 14) throw new ApiError("VALIDATION_ERROR", "Invalid barcode", { details: { field: "gtin" } });
  return digits.padStart(14, "0");
}

/** @param {string} gtin */
export const gtinKey = (gtin) => ({ PK: `GTIN#${normalizeGtin(gtin)}`, SK: "FOOD" });

/** Normalise free-text food search queries for the cache key. */
export function normalizeQuery(q) {
  return String(q ?? "").toLowerCase().normalize("NFKD").replace(/[^\p{L}\p{N} ]+/gu, " ").replace(/\s+/g, " ").trim().slice(0, 100);
}

/** @param {string} q */
export const searchKey = (q) => ({ PK: `SEARCH#${normalizeQuery(q).replace(/#/g, "")}`, SK: "RESULT" });

// ── Entity → key mapping (used by sync push and generic upserts) ────────────────────────────

/** Entity types that appear in the GSI1 change feed. */
export const SYNCABLE_TYPES = new Set([
  "profile", "goals", "connection", "meal", "dailyMetrics", "body", "workout", "customFood", "recipe", "note", "cycle",
]);

/**
 * Build the primary key for a syncable entity from its id and data.
 * @param {string} sub @param {string} entityType @param {string} id @param {Record<string, any>} data
 * @returns {Key}
 */
export function keyForEntity(sub, entityType, id, data = {}) {
  switch (entityType) {
    case "profile": return profileKey(sub);
    case "goals": return goalsKey(sub);
    case "connection": return connectionKey(sub, data.provider ?? id);
    case "meal": return mealKey(sub, data.date, id);
    case "dailyMetrics": return dayKey(sub, data.date, data.source);
    case "body": return bodyKey(sub, data.measuredAt, id);
    case "workout": return workoutKey(sub, data.start, id);
    case "customFood": return customFoodKey(sub, id);
    case "recipe": return recipeKey(sub, id);
    case "note": return noteKey(sub, data.date ?? id);
    case "cycle": return cycleKey(sub, data.date ?? id);
    default:
      throw new ApiError("VALIDATION_ERROR", `Unsupported entityType '${entityType}'`, { details: { field: "entityType" } });
  }
}

/** Stable entity id for a daily-metrics item. */
export const dailyMetricsId = (date, source) => `${seg(date, "date")}:${seg(source, "source")}`;
