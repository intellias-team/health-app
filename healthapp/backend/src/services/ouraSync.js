/**
 * Pull Oura data for one user and upsert it as `DAY#<date>#oura` and `WORKOUT#…` items.
 * Shared by POST /v1/integrations/oura/sync, the hourly schedule and the webhook worker.
 */
import { connectionKey, dailyMetricsId, dayKey, systemRateKey, workoutKey } from "../lib/keys.js";
import { addDays } from "../lib/dates.js";
import { mapOuraDailyMetrics, mapOuraWorkouts, OuraError } from "./oura.js";

const REFRESH_MARGIN_SEC = 120;

/**
 * Shared Oura client quota (Oura allows ~5000 requests / 5 min per app). A user sync makes ~8
 * requests, so at most 500 user syncs start per 5-minute window (`SYSTEM#oura` / `RATE#<window>`).
 */
export const OURA_SYNCS_PER_WINDOW = 500;
const OURA_WINDOW_MS = 5 * 60_000;

/** Reserve one sync from the app-wide Oura window or throw OuraError("rate_limited"). */
export async function reserveOuraQuota(repo, now) {
  const windowStart = Math.floor(now / OURA_WINDOW_MS) * OURA_WINDOW_MS;
  const window = new Date(windowStart).toISOString().slice(0, 16); // yyyy-mm-ddThh:mm
  const count = await repo.incrementBounded(systemRateKey("oura", window), OURA_SYNCS_PER_WINDOW, Math.floor(windowStart / 1000) + 3600);
  if (count === null) throw new OuraError("rate_limited", "App-wide Oura quota exhausted for this window");
}

/**
 * Return a valid access token, refreshing (and persisting the rotated pair) when near expiry.
 * @param {{ repo: any, vault: import("../lib/kms.js").TokenVault, oura: import("./oura.js").OuraClient, sub: string, connection: any, now: number }} p
 */
export async function getAccessToken({ repo, vault, oura, sub, connection, now }) {
  if (!connection?.tokenCiphertext) throw new OuraError("auth", "Oura not connected");
  const tokens = await vault.decrypt(sub, connection.tokenCiphertext);
  if (tokens.expires_at - REFRESH_MARGIN_SEC > now / 1000) return tokens.access_token;
  const fresh = await oura.refresh(tokens.refresh_token);
  const tokenCiphertext = await vault.encrypt(sub, {
    access_token: fresh.access_token,
    refresh_token: fresh.refresh_token ?? tokens.refresh_token,
    expires_at: fresh.expires_at,
  });
  await repo.patch(connectionKey(sub, "oura"), { tokenCiphertext });
  return fresh.access_token;
}

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   vault: import("../lib/kms.js").TokenVault,
 *   oura: import("./oura.js").OuraClient,
 *   sub: string,
 *   from?: string, to?: string,
 *   now?: number,
 *   logger?: any,
 * }} p
 * @returns {Promise<{ daysUpserted: number, workoutsUpserted: number }>}
 */
export async function syncOuraForUser({ repo, vault, oura, sub, from, to, now = Date.now(), logger }) {
  const connection = await repo.get(connectionKey(sub, "oura"));
  if (!connection || connection.status === "revoked") throw new OuraError("auth", "Oura not connected");
  const today = new Date(now).toISOString().slice(0, 10);
  const end = to ?? today;
  const start = from ?? addDays(end, -2);
  const enabled = new Set(connection.enabledMetrics ?? []);

  try {
    await reserveOuraQuota(repo, now);
    const accessToken = await getAccessToken({ repo, vault, oura, sub, connection, now });
    // Sleep periods are keyed by the day they end; fetch one extra day to catch the night before.
    const data = await oura.fetchRange(accessToken, addDays(start, -1), addDays(end, 1));

    let daysUpserted = 0;
    for (const [date, metrics] of mapOuraDailyMetrics(data)) {
      if (date < start || date > end) continue;
      const filtered = enabled.size ? Object.fromEntries(Object.entries(metrics).filter(([k]) => enabled.has(k) || k === "hrvMethod")) : metrics;
      if (!Object.keys(filtered).length) continue;
      const existing = await repo.get(dayKey(sub, date, "oura"));
      if (existing && JSON.stringify(existing.metrics) === JSON.stringify(filtered)) continue; // no change → no sync churn
      await repo.putVersioned(sub, dayKey(sub, date, "oura"), "dailyMetrics", dailyMetricsId(date, "oura"), { date, source: "oura", metrics: filtered });
      daysUpserted++;
    }

    let workoutsUpserted = 0;
    if (!enabled.size || enabled.has("workouts")) {
      for (const w of mapOuraWorkouts(data.workout)) {
        const day = w.start.slice(0, 10);
        if (day < addDays(start, -1) || day > end) continue;
        const key = workoutKey(sub, w.start, w.id);
        const existing = await repo.get(key);
        if (existing && existing.end === w.end && existing.activeKcal === w.activeKcal) continue;
        await repo.putVersioned(sub, key, "workout", w.id, w);
        workoutsUpserted++;
      }
    }

    await repo.patch(connectionKey(sub, "oura"), { status: "connected", lastSyncAt: new Date(now).toISOString(), lastError: undefined });
    return { daysUpserted, workoutsUpserted };
  } catch (err) {
    if (err instanceof OuraError) {
      await repo.patch(connectionKey(sub, "oura"), {
        status: err.kind === "auth" ? "error" : connection.status,
        lastError: err.kind === "auth" ? "authorization_failed" : err.kind,
      });
      logger?.warn("oura sync failed", { kind: err.kind, status: err.status });
    }
    throw err;
  }
}
