/**
 * notificationsScheduledFn — EventBridge `rate(15 minutes)`.
 * For each user with a registered push device: load state → `decideNotifications` → write the
 * `NOTIFLOG#<kind>#<date>` marker (conditional, so concurrent runs never double-send) → SNS → APNs.
 */
import { addDays, localDate, ttlAfterDays } from "../lib/dates.js";
import { deviceKey, notificationLogKey, skPrefix } from "../lib/keys.js";
import { isConditionalFailure } from "../lib/db.js";
import { EndpointDisabledError } from "../lib/messaging.js";
import { apnsMessage, decideNotifications } from "../services/notifications.js";
import { createUserData } from "../services/userData.js";
import * as d from "../lib/deps.js";

/**
 * Gather the decision state for one user.
 * @param {import("../lib/db.js").Repository} repo @param {string} sub @param {any[]} devices @param {number} now
 */
export async function loadNotificationState(repo, sub, devices, now) {
  const data = createUserData(repo, sub);
  const profile = await data.profile();
  const tz = profile.timezone ?? "UTC";
  const today = localDate(now, tz);
  const [goals, meals, daily, connections, logs] = await Promise.all([
    data.goals(),
    data.meals(today, today),
    data.daily(addDays(today, -28), today, profile.sourcePrecedence),
    repo.queryPrefix(skPrefix(sub, "CONNECTION")),
    repo.queryPrefix(skPrefix(sub, "NOTIFLOG")),
  ]);
  const newestDevice = [...devices].sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : -1))[0];
  return {
    timezone: tz,
    prefs: newestDevice?.notificationPrefs ?? {},
    goals,
    todayMeals: meals,
    todayMetrics: daily.find((x) => x.date === today)?.merged ?? {},
    recentDays: daily.filter((x) => x.date < today),
    connections,
    alreadySent: logs.map((l) => String(l.SK).slice("NOTIFLOG#".length)),
  };
}

/**
 * @param {{ repo: import("../lib/db.js").Repository, push: import("../lib/messaging.js").PushAdapter | null, now?: () => number, logger?: any }} deps
 */
export function createHandler(deps) {
  const { repo, push } = deps;
  const logger = deps.logger ?? d.logger;
  const now = deps.now ?? (() => Date.now());

  return async function handler() {
    if (!push) return { users: 0, sent: 0, skipped: "push not configured" };
    const devicesBySub = new Map();
    await repo.scanGsi2("PUSHDEVICE#", async (item) => {
      if (item.deleted || item.enabled === false || !item.endpointArn) return;
      const sub = String(item.PK).slice(5);
      if (!devicesBySub.has(sub)) devicesBySub.set(sub, []);
      devicesBySub.get(sub).push(item);
    });

    let sent = 0;
    for (const [sub, devices] of devicesBySub) {
      try {
        const state = await loadNotificationState(repo, sub, devices, now());
        for (const n of decideNotifications(state, now())) {
          try {
            await repo.putRaw({ ...notificationLogKey(sub, n.kind, n.date), sentAt: new Date(now()).toISOString(), type: n.type, expiresAt: ttlAfterDays(now(), 14) }, { ifNotExists: true });
          } catch (err) {
            if (isConditionalFailure(err)) continue; // already sent by a concurrent run
            throw err;
          }
          for (const dev of devices) {
            try {
              await push.publish(dev.endpointArn, apnsMessage(n));
              sent++;
            } catch (err) {
              if (err instanceof EndpointDisabledError) await repo.patch(deviceKey(sub, dev.id), { enabled: false });
              else logger.warn("push publish failed", { err });
            }
          }
        }
      } catch (err) {
        logger.error("notification evaluation failed", { err });
      }
    }
    const summary = { users: devicesBySub.size, sent };
    logger.info("notifications run", summary);
    return summary;
  };
}

export const handler = d.lazyHandler(createHandler, async () => ({ repo: await d.repository(), push: await d.pushAdapter() }));
