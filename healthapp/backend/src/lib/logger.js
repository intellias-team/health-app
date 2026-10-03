/**
 * Structured JSON logger. Never logs request/response bodies or free text supplied by users:
 * keys that commonly carry content are dropped, and user ids are logged only as a salted hash.
 */
import { createHash } from "node:crypto";

const REDACTED_KEYS = new Set([
  "body", "rawbody", "text", "transcript", "message", "messages", "content", "prompt", "photo",
  "image", "data", "token", "accesstoken", "refreshtoken", "access_token", "refresh_token",
  "authorization", "apnstoken", "email", "name", "displayname", "notes", "sub",
]);

/**
 * One-way hash of a Cognito sub for log correlation (not reversible without the salt).
 * @param {string} sub
 */
export function hashSub(sub) {
  const salt = process.env.LOG_HASH_SALT ?? "healthapp";
  return createHash("sha256").update(`${salt}:${sub}`).digest("hex").slice(0, 16);
}

function sanitize(value, depth = 0) {
  if (value instanceof Error) {
    return { name: value.name, message: value.message, code: value.code, status: value.status };
  }
  if (value === null || typeof value !== "object") return value;
  if (depth > 3) return "[depth]";
  if (Array.isArray(value)) return value.slice(0, 20).map((v) => sanitize(v, depth + 1));
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (REDACTED_KEYS.has(k.toLowerCase())) continue;
    out[k] = sanitize(v, depth + 1);
  }
  return out;
}

/**
 * @param {{ write?: (line: string) => void, base?: Record<string, unknown> }} [opts]
 */
export function createLogger(opts = {}) {
  const write = opts.write ?? ((line) => process.stdout.write(line + "\n"));
  const base = opts.base ?? { service: process.env.SERVICE_NAME ?? "healthapp" };
  const emit = (level, msg, fields) => {
    if (level === "debug" && process.env.LOG_LEVEL !== "debug") return;
    write(JSON.stringify({ level, msg, ts: new Date().toISOString(), ...base, ...sanitize(fields ?? {}) }));
  };
  return {
    debug: (msg, fields) => emit("debug", msg, fields),
    info: (msg, fields) => emit("info", msg, fields),
    warn: (msg, fields) => emit("warn", msg, fields),
    error: (msg, fields) => emit("error", msg, fields),
  };
}

/** Logger that discards everything (tests). */
export const silentLogger = { debug() {}, info() {}, warn() {}, error() {} };
