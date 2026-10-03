/**
 * profileFn — /v1/me*, /v1/connections*, /v1/devices
 */
import { ApiError, createRouter, json } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { connectionKey, deviceKey, goalsKey, gsi2DeviceKeys, profileKey, skPrefix } from "../lib/keys.js";
import { toPublic } from "../lib/db.js";
import { goalsSchema, profileSchema, DAILY_METRIC_KEYS } from "../lib/schemas.js";
import { exportKey, EXPORT_RETENTION_TAG, userPrefix } from "../lib/s3.js";
import { createZip } from "../lib/zip.js";
import { getAccessToken } from "../services/ouraSync.js";
import * as d from "../lib/deps.js";

const PROVIDER_RE = /^(healthkit|oura|bodyscale:[A-Za-z0-9_-]{1,64}|foodscale:[A-Za-z0-9_-]{1,64})$/;
const ENABLED_METRICS = [...DAILY_METRIC_KEYS, "workouts", "body", "nutrition", "weightKg", "bodyFatPct"];

const connectionUpdateSchema = v.object({
  enabledMetrics: v.default(v.array(v.string({ enum: ENABLED_METRICS }), { max: 50 }), []),
  status: v.string({ enum: ["connected", "revoked"] }),
});

const deviceSchema = v.object({
  id: v.id(),
  apnsToken: v.string({ pattern: /^[0-9a-fA-F]{32,200}$/ }),
  platform: v.default(v.string({ enum: ["ios"] }), "ios"),
  appVersion: v.optional(v.string({ max: 32 })),
  notificationPrefs: v.default(v.object({
    mealReminder: v.optional(v.boolean()),
    mealReminderTime: v.optional(v.string({ pattern: /^([01]\d|2[0-3]):[0-5]\d$/ })),
    hydration: v.optional(v.boolean()),
    hydrationTime: v.optional(v.string({ pattern: /^([01]\d|2[0-3]):[0-5]\d$/ })),
    recovery: v.optional(v.boolean()),
    sleepConsistency: v.optional(v.boolean()),
    proteinProgress: v.optional(v.boolean()),
    proteinTime: v.optional(v.string({ pattern: /^([01]\d|2[0-3]):[0-5]\d$/ })),
    deviceSync: v.optional(v.boolean()),
    quietStart: v.optional(v.string({ pattern: /^([01]\d|2[0-3]):[0-5]\d$/ })),
    quietEnd: v.optional(v.string({ pattern: /^([01]\d|2[0-3]):[0-5]\d$/ })),
  }), {}),
});

/** Public view of a connection: never exposes token ciphertext or GSI keys. */
export const publicConnection = (c) => {
  const { ouraUserId, ...rest } = toPublic(c);
  return rest;
};

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   media: import("../lib/s3.js").MediaStore,
 *   push?: import("../lib/messaging.js").PushAdapter | null,
 *   revokeOura?: (sub: string, connection: any) => Promise<void>,
 *   logger?: any,
 * }} deps
 */
export function createHandler(deps) {
  const { repo, media, push } = deps;
  const logger = deps.logger ?? d.logger;

  async function connections(sub) {
    return (await repo.queryPrefix(skPrefix(sub, "CONNECTION"))).map(publicConnection);
  }

  return createRouter([
    {
      // Public liveness check used by deploy smoke tests; touches no user data.
      method: "GET", path: "/v1/health", public: true,
      handler: async () => json(200, { status: "ok", stage: process.env.STAGE ?? "local", time: new Date().toISOString() }),
    },
    {
      method: "GET", path: "/v1/me",
      handler: async ({ sub }) => {
        const [profile, goals, conns] = await Promise.all([repo.get(profileKey(sub)), repo.get(goalsKey(sub)), connections(sub)]);
        return json(200, { profile: toPublic(profile) ?? null, goals: toPublic(goals) ?? null, connections: conns });
      },
    },
    {
      method: "PUT", path: "/v1/me",
      handler: async ({ sub, body }) => {
        const patch = validate(profileSchema, body ?? {});
        const current = await repo.get(profileKey(sub));
        const merged = { ...(current ? toPublic(current) : { createdAt: repo.iso() }), ...patch };
        const profile = await repo.putVersioned(sub, profileKey(sub), "profile", "profile", merged);
        return json(200, { profile: toPublic(profile) });
      },
    },
    {
      method: "PUT", path: "/v1/me/goals",
      handler: async ({ sub, body }) => {
        const goals = validate(goalsSchema, body ?? {});
        const saved = await repo.putVersioned(sub, goalsKey(sub), "goals", "goals", goals);
        return json(200, { goals: toPublic(saved) });
      },
    },
    {
      method: "DELETE", path: "/v1/me",
      handler: async ({ sub }) => {
        // 1. Revoke Oura (best effort — deletion must not be blocked by a third party).
        const oura = await repo.get(connectionKey(sub, "oura"));
        if (oura?.tokenCiphertext && deps.revokeOura) {
          await deps.revokeOura(sub, oura).catch((err) => logger.warn("oura revoke failed during account deletion", { err }));
        }
        // 2. Push endpoints
        const devices = await repo.queryPrefix(skPrefix(sub, "DEVICE"), { includeDeleted: true });
        for (const dev of devices) {
          if (dev.endpointArn && push) await push.deleteEndpoint(dev.endpointArn).catch(() => undefined);
        }
        // 3. S3 media + exports
        const objects = await media.deletePrefix(userPrefix(sub));
        // 4. Every USER# item (batched)
        const items = await repo.listUserItems(sub);
        const deleted = await repo.batchDelete(items.map(({ PK, SK }) => ({ PK, SK })));
        logger.info("account deleted", { items: deleted, objects });
        return json(202, { status: "deleted", itemsDeleted: deleted, objectsDeleted: objects });
      },
    },
    {
      method: "POST", path: "/v1/me/export",
      handler: async ({ sub }) => {
        const items = (await repo.listUserItems(sub))
          .filter((i) => !i.deleted && !String(i.SK).startsWith("RATE#") && !String(i.SK).startsWith("NOTIFLOG#"))
          .map((i) => ({ type: i.entityType ?? String(i.SK).split("#")[0].toLowerCase(), ...toPublic(i) }));
        const grouped = {};
        for (const i of items) (grouped[i.type] ??= []).push(i);
        const ts = repo.iso().replace(/[:.]/g, "-");
        const zip = createZip([
          { name: "README.txt", data: "HealthApp data export. data.json contains every record stored for your account, grouped by type. Meal photos are not included.\n" },
          { name: "data.json", data: JSON.stringify({ exportedAt: repo.iso(), records: grouped }, null, 2) },
        ]);
        const key = exportKey(sub, ts);
        await media.putObject({ key, body: zip, contentType: "application/zip", tagging: EXPORT_RETENTION_TAG });
        const downloadUrl = await media.presignGet({ key, expiresIn: 900 });
        return json(200, { downloadUrl, expiresIn: 900 });
      },
    },
    {
      method: "GET", path: "/v1/connections",
      handler: async ({ sub }) => json(200, { connections: await connections(sub) }),
    },
    {
      method: "PUT", path: "/v1/connections/{provider}",
      handler: async ({ sub, params, body }) => {
        const provider = params.provider;
        if (!PROVIDER_RE.test(provider)) throw new ApiError("VALIDATION_ERROR", "Unknown provider", { details: { field: "provider" } });
        const update = validate(connectionUpdateSchema, body ?? {});
        const current = await repo.get(connectionKey(sub, provider));
        if (provider === "oura" && update.status === "connected" && !current?.tokenCiphertext) {
          throw new ApiError("CONFLICT", "Connect Oura via /v1/integrations/oura/authorize first");
        }
        const extra = {};
        if (current?.tokenCiphertext) extra.tokenCiphertext = current.tokenCiphertext;
        if (current?.GSI2PK) Object.assign(extra, { GSI2PK: current.GSI2PK, GSI2SK: current.GSI2SK });
        const attrs = { ...(current ? toPublic(current) : {}), provider, enabledMetrics: update.enabledMetrics, status: update.status };
        const saved = await repo.putVersioned(sub, connectionKey(sub, provider), "connection", provider, attrs, { extra });
        return json(200, { connection: publicConnection(saved) });
      },
    },
    {
      method: "POST", path: "/v1/devices",
      handler: async ({ sub, body }) => {
        const dev = validate(deviceSchema, body ?? {});
        const current = await repo.get(deviceKey(sub, dev.id));
        let endpointArn = current?.endpointArn;
        if (push) {
          if (endpointArn && current.apnsToken !== dev.apnsToken) await push.refreshEndpoint(endpointArn, dev.apnsToken);
          if (!endpointArn) endpointArn = await push.createEndpoint({ token: dev.apnsToken });
        }
        const saved = await repo.putVersioned(sub, deviceKey(sub, dev.id), "device", dev.id, { ...dev, endpointArn, enabled: true }, {
          extra: gsi2DeviceKeys(sub, dev.id),
        });
        const { endpointArn: _omit, ...device } = toPublic(saved);
        return json(200, { device });
      },
    },
  ], { logger });
}

/** Revoke an Oura token for a user (used by account deletion). */
async function revokeOura(sub, connection) {
  const [repo, vault, oura] = await Promise.all([d.repository(), d.tokenVault(), d.ouraClient()]);
  const token = await getAccessToken({ repo, vault, oura, sub, connection, now: Date.now() });
  await oura.revoke(token);
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  media: await d.mediaStore(),
  push: await d.pushAdapter(),
  revokeOura,
}));
