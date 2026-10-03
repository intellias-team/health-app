/**
 * ouraFn — /v1/integrations/oura/*, /v1/webhooks/oura (public, signature-verified)
 */
import { ApiError, createRouter, json, noContent, redirect } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { connectionKey, gsi2OuraKeys, oauthStateKey } from "../lib/keys.js";
import { isConditionalFailure, toPublic } from "../lib/db.js";
import { addDays, daysBetween, ttlAfterDays } from "../lib/dates.js";
import { createOAuthState, OURA_SCOPES, OuraError, verifySubscriptionChallenge, verifyWebhookSignature } from "../services/oura.js";
import { getAccessToken, syncOuraForUser } from "../services/ouraSync.js";
import * as d from "../lib/deps.js";

const syncSchema = v.object({ from: v.optional(v.date()), to: v.optional(v.date()) });

/** Map Oura failures to API errors. */
function ouraApiError(err) {
  if (!(err instanceof OuraError)) return err;
  if (err.kind === "auth") return new ApiError("CONFLICT", "Oura authorization is no longer valid; please reconnect", { details: { reason: "reconnect_required" } });
  if (err.kind === "rate_limited") return new ApiError("RATE_LIMITED", "Oura is rate limiting requests; try again later");
  return new ApiError("UPSTREAM_ERROR", "Oura is unavailable");
}

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   vault: import("../lib/kms.js").TokenVault,
 *   oura: import("../services/oura.js").OuraClient,
 *   queue: { send: (body: unknown) => Promise<void> },
 *   getOuraSecret: () => Promise<{ clientSecret: string, webhookVerificationToken: string }>,
 *   appScheme?: string,
 *   usePkce?: boolean,
 *   redirectUri?: string,
 *   now?: () => number,
 *   logger?: any,
 * }} deps
 */
export function createHandler(deps) {
  const { repo, vault, oura, queue } = deps;
  const logger = deps.logger ?? d.logger;
  const now = deps.now ?? (() => repo.now());
  const scheme = deps.appScheme ?? "healthapp";
  /** Oura redirect URI: configured, or derived from the API's own domain (avoids a template cycle). */
  const redirectUriFor = (req) => deps.redirectUri ?? `https://${req.event?.requestContext?.domainName ?? req.headers.host}/v1/integrations/oura/callback`;
  const fail = (reason) => redirect(`${scheme}://oura/error?reason=${encodeURIComponent(reason)}`);

  return createRouter([
    {
      method: "POST", path: "/v1/integrations/oura/authorize",
      handler: async (req) => {
        const { sub } = req;
        const { state, codeVerifier, codeChallenge } = createOAuthState();
        await repo.putRaw({
          ...oauthStateKey(state),
          sub,
          provider: "oura",
          // PKCE only when the provider supports it; the server-held client secret protects the exchange regardless.
          ...(deps.usePkce ? { codeVerifier } : {}),
          expiresAt: ttlAfterDays(now(), 10 / 1440),
        });
        return json(200, { authorizeUrl: oura.authorizeUrl({ state, codeChallenge: deps.usePkce ? codeChallenge : undefined, redirectUri: redirectUriFor(req) }) });
      },
    },
    {
      method: "GET", path: "/v1/integrations/oura/callback", public: true,
      handler: async (req) => {
        const { query } = req;
        if (query.error) return fail(query.error === "access_denied" ? "access_denied" : "oauth_error");
        if (!query.code || !query.state || !/^[A-Za-z0-9_-]{20,100}$/.test(query.state)) return fail("invalid_request");
        // Consume the state exactly once (conditional delete prevents replay).
        let stateItem;
        try {
          stateItem = await repo.deleteRaw(oauthStateKey(query.state), { mustExist: true, returnOld: true });
        } catch (err) {
          if (isConditionalFailure(err)) return fail("invalid_state");
          throw err;
        }
        if (!stateItem || stateItem.provider !== "oura" || stateItem.expiresAt * 1000 < now()) return fail("expired_state");
        const sub = stateItem.sub;
        try {
          const tokens = await oura.exchangeCode(query.code, stateItem.codeVerifier, redirectUriFor(req));
          const info = await oura.personalInfo(tokens.access_token);
          const tokenCiphertext = await vault.encrypt(sub, { access_token: tokens.access_token, refresh_token: tokens.refresh_token, expires_at: tokens.expires_at });
          const current = await repo.get(connectionKey(sub, "oura"), { includeDeleted: true });
          await repo.putVersioned(sub, connectionKey(sub, "oura"), "connection", "oura", {
            provider: "oura",
            status: "connected",
            scopes: tokens.scope ? String(tokens.scope).split(/\s+/) : OURA_SCOPES,
            enabledMetrics: current?.enabledMetrics ?? [],
            ouraUserId: String(info.id),
            connectedAt: new Date(now()).toISOString(),
          }, { extra: { tokenCiphertext, ...gsi2OuraKeys(String(info.id)) } });
          // Initial 30-day backfill runs asynchronously in the webhook worker.
          await queue.send({ kind: "backfill", sub, from: addDays(new Date(now()).toISOString().slice(0, 10), -30) });
          return redirect(`${scheme}://oura/connected`);
        } catch (err) {
          logger.warn("oura connect failed", { err });
          return fail(err instanceof OuraError && err.kind === "auth" ? "token_exchange_failed" : "server_error");
        }
      },
    },
    {
      method: "POST", path: "/v1/integrations/oura/sync",
      handler: async ({ sub, body }) => {
        const input = validate(syncSchema, body ?? {});
        const to = input.to ?? new Date(now()).toISOString().slice(0, 10);
        const from = input.from ?? addDays(to, -6);
        if (from > to || daysBetween(from, to) > 90) throw new ApiError("VALIDATION_ERROR", "from/to must span at most 90 days");
        try {
          return json(200, await syncOuraForUser({ repo, vault, oura, sub, from, to, now: now(), logger }));
        } catch (err) {
          throw ouraApiError(err);
        }
      },
    },
    {
      method: "DELETE", path: "/v1/integrations/oura",
      handler: async ({ sub }) => {
        const current = await repo.get(connectionKey(sub, "oura"));
        if (!current) return noContent();
        if (current.tokenCiphertext) {
          try {
            const token = await getAccessToken({ repo, vault, oura, sub, connection: current, now: now() });
            await oura.revoke(token);
          } catch (err) {
            logger.warn("oura revoke failed", { err }); // still remove our copy of the tokens
          }
        }
        const { ouraUserId, lastError, ...rest } = toPublic(current);
        // No `extra`: tokenCiphertext and GSI2 keys are dropped from the item.
        await repo.putVersioned(sub, connectionKey(sub, "oura"), "connection", "oura", { ...rest, status: "revoked", revokedAt: new Date(now()).toISOString() });
        return noContent();
      },
    },
    {
      method: "GET", path: "/v1/webhooks/oura", public: true,
      handler: async ({ query }) => {
        const secret = await deps.getOuraSecret();
        const ok = verifySubscriptionChallenge({ verificationToken: query.verification_token, challenge: query.challenge, expectedToken: secret.webhookVerificationToken });
        if (!ok) throw new ApiError("UNAUTHORIZED", "Invalid verification token");
        return json(200, ok);
      },
    },
    {
      method: "POST", path: "/v1/webhooks/oura", public: true,
      handler: async ({ rawBody, headers, body }) => {
        const secret = await deps.getOuraSecret();
        const valid = verifyWebhookSignature({
          rawBody, signature: headers["x-oura-signature"], timestamp: headers["x-oura-timestamp"], clientSecret: secret.clientSecret, now: now(),
        });
        if (!valid) throw new ApiError("UNAUTHORIZED", "Invalid signature");
        const event = validate(v.object({
          event_type: v.string({ enum: ["create", "update", "delete"] }),
          data_type: v.string({ max: 64 }),
          object_id: v.optional(v.string({ max: 128 })),
          event_time: v.optional(v.string({ max: 64 })),
          user_id: v.string({ max: 128 }),
        }), body ?? {});
        await queue.send({ kind: "webhook", event });
        return json(200, { received: true });
      },
    },
  ], { logger });
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  vault: await d.tokenVault(),
  oura: await d.ouraClient(),
  queue: await d.ouraQueue(),
  getOuraSecret: d.ouraSecret,
  appScheme: process.env.APP_SCHEME ?? "healthapp",
  usePkce: process.env.OURA_USE_PKCE === "true",
  redirectUri: process.env.OURA_REDIRECT_URI || (await ouraRedirectFromPublicUrl()),
}));

/** `<CloudFront base>/v1/integrations/oura/callback`, or undefined to fall back to the request domain. */
async function ouraRedirectFromPublicUrl() {
  const base = await d.publicBaseUrl();
  return base ? `${base}/v1/integrations/oura/callback` : undefined;
}
