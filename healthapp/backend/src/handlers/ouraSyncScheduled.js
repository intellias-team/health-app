/**
 * ouraSyncScheduledFn — EventBridge `rate(1 hour)`: pull the last 2 days for every connected
 * Oura user (found via the sparse GSI2 `OURAUSER#…` items). Stops early if the app-wide Oura
 * quota window is exhausted; the next run picks up the rest.
 */
import { OuraError } from "../services/oura.js";
import { syncOuraForUser } from "../services/ouraSync.js";
import * as d from "../lib/deps.js";

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   vault: import("../lib/kms.js").TokenVault,
 *   oura: import("../services/oura.js").OuraClient,
 *   now?: () => number,
 *   concurrency?: number,
 *   logger?: any,
 * }} deps
 */
export function createHandler(deps) {
  const logger = deps.logger ?? d.logger;
  const now = deps.now ?? (() => Date.now());
  const concurrency = deps.concurrency ?? 4;

  return async function handler() {
    const subs = [];
    await deps.repo.scanGsi2("OURAUSER#", async (item) => {
      if (item.status === "connected" && String(item.PK).startsWith("USER#")) subs.push(item.PK.slice(5));
    });

    const summary = { users: subs.length, synced: 0, failed: 0, skipped: 0, daysUpserted: 0, workoutsUpserted: 0 };
    let quotaExhausted = false;
    let next = 0;
    const worker = async () => {
      while (next < subs.length && !quotaExhausted) {
        const sub = subs[next++];
        try {
          const r = await syncOuraForUser({ repo: deps.repo, vault: deps.vault, oura: deps.oura, sub, now: now(), logger });
          summary.synced++;
          summary.daysUpserted += r.daysUpserted;
          summary.workoutsUpserted += r.workoutsUpserted;
        } catch (err) {
          summary.failed++;
          if (err instanceof OuraError && err.kind === "rate_limited") quotaExhausted = true;
          else if (!(err instanceof OuraError)) logger.error("scheduled oura sync error", { err });
        }
      }
    };
    await Promise.all(Array.from({ length: Math.min(concurrency, subs.length) }, worker));
    summary.skipped = subs.length - summary.synced - summary.failed;
    logger.info("scheduled oura sync", summary);
    return summary;
  };
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  vault: await d.tokenVault(),
  oura: await d.ouraClient(),
}));
