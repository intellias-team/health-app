/**
 * Per-user AI rate limit (API §3.1: 30 requests / hour / user), fixed hourly window stored as a
 * DynamoDB counter item under the user's partition (so account deletion removes it too).
 */
import { ApiError } from "./http.js";
import { rateKey } from "./keys.js";

export const AI_LIMIT_PER_HOUR = 30;

/**
 * Consume one unit or throw 429.
 * @param {import("./db.js").Repository} repo
 * @param {string} sub
 * @param {{ bucket?: string, limit?: number, now?: number }} [opts]
 * @returns {Promise<{ count: number, remaining: number }>}
 */
export async function consumeAiQuota(repo, sub, opts = {}) {
  const limit = opts.limit ?? AI_LIMIT_PER_HOUR;
  const nowMs = opts.now ?? repo.now();
  const windowStart = Math.floor(nowMs / 3_600_000) * 3_600_000;
  const window = new Date(windowStart).toISOString().slice(0, 13); // yyyy-mm-ddThh
  const expiresAt = Math.floor(windowStart / 1000) + 2 * 3600;
  const count = await repo.incrementBounded(rateKey(sub, opts.bucket ?? "ai", window), limit, expiresAt);
  if (count === null) {
    const retryAfter = Math.max(1, Math.ceil((windowStart + 3_600_000 - nowMs) / 1000));
    throw new ApiError("RATE_LIMITED", "AI request limit reached, try again later", {
      details: { limit, retryAfterSeconds: retryAfter },
      headers: { "retry-after": String(retryAfter) },
    });
  }
  return { count, remaining: limit - count };
}
