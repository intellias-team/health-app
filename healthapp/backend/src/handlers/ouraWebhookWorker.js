/**
 * ouraWebhookWorker — SQS consumer for Oura webhook events and post-connect backfills.
 *
 * For create/update events the changed document is fetched to learn which day it belongs to;
 * delete events (and documents that are already gone) fall back to the event date. Events are
 * grouped per user so a burst becomes one sync per user. Uses partial batch failure reporting.
 */
import { connectionKey } from "../lib/keys.js";
import { addDays } from "../lib/dates.js";
import { getAccessToken, syncOuraForUser } from "../services/ouraSync.js";
import * as d from "../lib/deps.js";

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   vault: import("../lib/kms.js").TokenVault,
 *   oura: import("../services/oura.js").OuraClient,
 *   now?: () => number,
 *   logger?: any,
 * }} deps
 */
export function createHandler(deps) {
  const { repo, vault, oura } = deps;
  const logger = deps.logger ?? d.logger;
  const now = deps.now ?? (() => Date.now());

  async function resolveSub(ouraUserId) {
    const items = await repo.queryGsi2(`OURAUSER#${ouraUserId}`);
    const conn = items.find((i) => i.status === "connected");
    return conn ? conn.PK.slice(5) : undefined;
  }

  /** Day of the changed document (or the event date as fallback). */
  async function dayForEvent(sub, event) {
    const fallback = (event.event_time ? new Date(event.event_time) : new Date(now())).toISOString().slice(0, 10);
    if (event.event_type === "delete" || !event.object_id) return fallback;
    const connection = await repo.get(connectionKey(sub, "oura"));
    const token = await getAccessToken({ repo, vault, oura, sub, connection, now: now() });
    const doc = await oura.getDocument(token, event.data_type, event.object_id);
    return doc?.day ?? (doc?.start_datetime ? String(doc.start_datetime).slice(0, 10) : fallback);
  }

  return async function handler(event) {
    /** @type {Map<string, { from: string, to: string, messageIds: string[] }>} */
    const perUser = new Map();
    const failures = [];
    const widen = (sub, from, to, messageId) => {
      const cur = perUser.get(sub) ?? { from, to, messageIds: [] };
      cur.from = from < cur.from ? from : cur.from;
      cur.to = to > cur.to ? to : cur.to;
      cur.messageIds.push(messageId);
      perUser.set(sub, cur);
    };

    for (const record of event.Records ?? []) {
      try {
        const msg = JSON.parse(record.body);
        const today = new Date(now()).toISOString().slice(0, 10);
        if (msg.kind === "backfill" && msg.sub) {
          widen(msg.sub, msg.from ?? addDays(today, -30), today, record.messageId);
        } else if (msg.kind === "webhook" && msg.event?.user_id) {
          const sub = await resolveSub(String(msg.event.user_id));
          if (!sub) continue; // unknown or disconnected user: drop
          const day = await dayForEvent(sub, msg.event);
          widen(sub, addDays(day, -1), day > today ? today : day, record.messageId);
        }
      } catch (err) {
        logger.warn("webhook record failed", { err });
        failures.push({ itemIdentifier: record.messageId });
      }
    }

    for (const [sub, range] of perUser) {
      try {
        await syncOuraForUser({ repo, vault, oura, sub, from: range.from, to: range.to, now: now(), logger });
      } catch (err) {
        if (err?.kind === "auth") continue; // connection marked as error; retrying won't help
        for (const id of range.messageIds) failures.push({ itemIdentifier: id });
      }
    }
    return { batchItemFailures: failures };
  };
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  vault: await d.tokenVault(),
  oura: await d.ouraClient(),
}));
