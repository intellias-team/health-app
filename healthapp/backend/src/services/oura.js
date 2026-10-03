/**
 * Oura API v2 client: OAuth2 (authorize URL, code exchange, refresh, revoke), paginated
 * `usercollection` fetches, mapping to our normalised daily metrics + workouts, and webhook
 * verification. `fetch` is injectable for tests.
 */
import { createHash, createHmac, randomBytes, timingSafeEqual } from "node:crypto";

export const OURA_AUTHORIZE_URL = "https://cloud.ouraring.com/oauth/authorize";
export const OURA_TOKEN_URL = "https://api.ouraring.com/oauth/token";
export const OURA_REVOKE_URL = "https://api.ouraring.com/oauth/revoke";
export const OURA_API_BASE = "https://api.ouraring.com/v2";
export const OURA_SCOPES = ["personal", "daily", "heartrate", "workout", "session", "spo2Daily"];
export const OURA_COLLECTIONS = ["daily_sleep", "daily_readiness", "daily_activity", "sleep", "workout", "daily_spo2"];
const WEBHOOK_MAX_SKEW_SEC = 300;

/** Error raised for Oura API failures; `kind` drives connection status handling. */
export class OuraError extends Error {
  /** @param {"auth"|"rate_limited"|"upstream"} kind @param {string} message @param {number} [status] */
  constructor(kind, message, status) {
    super(message);
    this.name = "OuraError";
    this.kind = kind;
    this.status = status;
  }
}

const b64url = (buf) => Buffer.from(buf).toString("base64url");

/** Random OAuth `state` and PKCE verifier/challenge (S256). */
export function createOAuthState() {
  const state = b64url(randomBytes(32));
  const codeVerifier = b64url(randomBytes(48));
  const codeChallenge = b64url(createHash("sha256").update(codeVerifier).digest());
  return { state, codeVerifier, codeChallenge };
}

/**
 * @param {{ clientId: string, clientSecret: string, redirectUri?: string, fetch?: typeof fetch, now?: () => number }} opts
 *        `redirectUri` may instead be passed per call (it is derived from the API domain at runtime).
 */
export function createOuraClient({ clientId, clientSecret, redirectUri, fetch: fetchImpl = globalThis.fetch, now = () => Date.now() }) {
  /** @returns {Promise<any>} */
  async function tokenRequest(params) {
    const res = await fetchImpl(OURA_TOKEN_URL, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
      body: new URLSearchParams({ ...params, client_id: clientId, client_secret: clientSecret }).toString(),
      signal: AbortSignal.timeout(10_000),
    });
    if (res.status === 400 || res.status === 401) throw new OuraError("auth", `Oura token endpoint rejected request (${res.status})`, res.status);
    if (!res.ok) throw new OuraError("upstream", `Oura token endpoint error ${res.status}`, res.status);
    const body = await res.json();
    return {
      access_token: body.access_token,
      refresh_token: body.refresh_token,
      expires_at: Math.floor(now() / 1000) + Number(body.expires_in ?? 86_400),
      scope: body.scope,
    };
  }

  /**
   * GET a v2 endpoint, following `next_token` pagination for collections.
   * @param {string} accessToken @param {string} path e.g. `usercollection/daily_sleep`
   * @param {Record<string,string>} [params]
   * @returns {Promise<any[]>}
   */
  async function fetchCollection(accessToken, path, params = {}) {
    const out = [];
    let nextToken;
    let pages = 0;
    do {
      const qs = new URLSearchParams({ ...params, ...(nextToken ? { next_token: nextToken } : {}) });
      const json = await getJson(accessToken, `${path}?${qs}`);
      out.push(...(json.data ?? []));
      nextToken = json.next_token ?? undefined;
      if (++pages > 50) break; // safety valve
    } while (nextToken);
    return out;
  }

  async function getJson(accessToken, pathAndQuery) {
    const res = await fetchImpl(`${OURA_API_BASE}/${pathAndQuery}`, {
      headers: { authorization: `Bearer ${accessToken}`, accept: "application/json" },
      signal: AbortSignal.timeout(15_000),
    });
    if (res.status === 401 || res.status === 403) throw new OuraError("auth", `Oura API unauthorized (${res.status})`, res.status);
    if (res.status === 429) throw new OuraError("rate_limited", "Oura API rate limited", 429);
    if (!res.ok) throw new OuraError("upstream", `Oura API error ${res.status}`, res.status);
    return res.json();
  }

  return {
    /**
     * @param {{ state: string, codeChallenge?: string, scopes?: string[], redirectUri?: string }} p
     */
    authorizeUrl({ state, codeChallenge, scopes = OURA_SCOPES, redirectUri: ru = redirectUri }) {
      const url = new URL(OURA_AUTHORIZE_URL);
      url.searchParams.set("response_type", "code");
      url.searchParams.set("client_id", clientId);
      url.searchParams.set("redirect_uri", ru);
      url.searchParams.set("scope", scopes.join(" "));
      url.searchParams.set("state", state);
      if (codeChallenge) {
        url.searchParams.set("code_challenge", codeChallenge);
        url.searchParams.set("code_challenge_method", "S256");
      }
      return url.toString();
    },
    /** @param {string} code @param {string} [codeVerifier] @param {string} [ru] redirect URI used in the authorize step */
    exchangeCode(code, codeVerifier, ru = redirectUri) {
      return tokenRequest({ grant_type: "authorization_code", code, redirect_uri: ru, ...(codeVerifier ? { code_verifier: codeVerifier } : {}) });
    },
    /** Oura refresh tokens are single-use: persist the returned pair immediately. */
    refresh(refreshToken) {
      return tokenRequest({ grant_type: "refresh_token", refresh_token: refreshToken });
    },
    /** Revoke an access token (best effort). */
    async revoke(accessToken) {
      const res = await fetchImpl(`${OURA_REVOKE_URL}?access_token=${encodeURIComponent(accessToken)}`, { method: "GET", signal: AbortSignal.timeout(10_000) });
      return res.ok;
    },
    /** Fetch one changed document (webhook follow-up), e.g. `daily_sleep/<id>`. Undefined if gone. */
    async getDocument(accessToken, dataType, documentId) {
      if (!OURA_COLLECTIONS.includes(dataType) || !/^[A-Za-z0-9_-]{1,128}$/.test(documentId)) return undefined;
      try {
        return await getJson(accessToken, `usercollection/${dataType}/${documentId}`);
      } catch (err) {
        if (err instanceof OuraError && err.status === 404) return undefined;
        throw err;
      }
    },
    personalInfo(accessToken) {
      return getJson(accessToken, "usercollection/personal_info");
    },
    fetchCollection,
    /**
     * Fetch every collection we map for [startDate, endDate].
     * Note: Oura's `sleep`/`workout` collections filter on the day the period *ends*.
     */
    async fetchRange(accessToken, startDate, endDate, collections = OURA_COLLECTIONS) {
      const result = {};
      for (const c of collections) {
        result[c] = await fetchCollection(accessToken, `usercollection/${c}`, { start_date: startDate, end_date: endDate });
      }
      return result;
    },
  };
}

/** @typedef {ReturnType<typeof createOuraClient>} OuraClient */

const minutes = (sec) => (typeof sec === "number" ? Math.round(sec / 60) : undefined);
const clean = (obj) => Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined && v !== null && !(typeof v === "number" && Number.isNaN(v))));

/**
 * Map Oura collections to normalised daily metrics (schema §2.2.3) keyed by date.
 * For `sleep`, the main period of each day (type `long_sleep`, else the longest) is used.
 * @param {{ daily_sleep?: any[], daily_readiness?: any[], daily_activity?: any[], sleep?: any[], daily_spo2?: any[] }} c
 * @returns {Map<string, Record<string, any>>}
 */
export function mapOuraDailyMetrics(c) {
  const days = new Map();
  const at = (day) => {
    if (!days.has(day)) days.set(day, {});
    return days.get(day);
  };

  for (const s of c.daily_sleep ?? []) if (s.day) Object.assign(at(s.day), clean({ sleepScore: s.score }));
  for (const r of c.daily_readiness ?? []) {
    if (r.day) Object.assign(at(r.day), clean({ readinessScore: r.score, tempDeviationC: r.temperature_deviation }));
  }
  for (const a of c.daily_activity ?? []) {
    if (!a.day) continue;
    const resting = typeof a.total_calories === "number" && typeof a.active_calories === "number" ? a.total_calories - a.active_calories : undefined;
    Object.assign(at(a.day), clean({ steps: a.steps, activeKcal: a.active_calories, restingKcal: resting, activityScore: a.score }));
  }
  for (const o of c.daily_spo2 ?? []) {
    if (o.day) Object.assign(at(o.day), clean({ spo2Pct: o.spo2_percentage?.average }));
  }

  const mainSleep = new Map();
  for (const s of c.sleep ?? []) {
    if (!s.day) continue;
    const cur = mainSleep.get(s.day);
    const score = (x) => (x.type === "long_sleep" ? 1e9 : 0) + (x.total_sleep_duration ?? 0);
    if (!cur || score(s) > score(cur)) mainSleep.set(s.day, s);
  }
  // Naps / secondary periods of the same day (everything that isn't the main period).
  const napSeconds = new Map();
  for (const s of c.sleep ?? []) {
    if (!s.day || s.type === "deleted" || mainSleep.get(s.day) === s) continue;
    napSeconds.set(s.day, (napSeconds.get(s.day) ?? 0) + (s.total_sleep_duration ?? 0));
  }
  for (const [day, s] of mainSleep) {
    Object.assign(at(day), clean({
      sleepMinutes: minutes(s.total_sleep_duration),
      sleepStages: clean({
        coreMin: minutes(s.light_sleep_duration), // Oura "light" ≈ Apple "core"
        deepMin: minutes(s.deep_sleep_duration),
        remMin: minutes(s.rem_sleep_duration),
        awakeMin: minutes(s.awake_time),
        inBedMin: minutes(s.time_in_bed),
        napMin: napSeconds.has(day) ? minutes(napSeconds.get(day)) : undefined,
      }),
      restingHr: s.lowest_heart_rate,
      restingHrMethod: typeof s.lowest_heart_rate === "number" ? "sleepLowest" : undefined,
      hrvMs: s.average_hrv,
      hrvMethod: typeof s.average_hrv === "number" ? "rmssd" : undefined,
      respiratoryRate: s.average_breath,
      bedtimeStart: s.bedtime_start ? new Date(s.bedtime_start).toISOString() : undefined,
    }));
  }
  for (const [day, m] of days) {
    if (m.sleepStages && Object.keys(m.sleepStages).length === 0) delete m.sleepStages;
    if (Object.keys(m).length === 0) days.delete(day);
  }
  return days;
}

/**
 * Map Oura workouts to our Workout shape.
 * @param {any[]} workouts
 */
export function mapOuraWorkouts(workouts = []) {
  return workouts
    .filter((w) => w.id && w.start_datetime && w.end_datetime)
    .map((w) => {
      const start = new Date(w.start_datetime).toISOString();
      const end = new Date(w.end_datetime).toISOString();
      return clean({
        id: `oura-${w.id}`,
        start,
        end,
        type: w.activity ?? "workout",
        source: "oura",
        durationMin: Math.round((Date.parse(end) - Date.parse(start)) / 60_000),
        activeKcal: typeof w.calories === "number" ? Math.round(w.calories) : undefined,
        distanceM: typeof w.distance === "number" ? Math.round(w.distance) : undefined,
        intensity: w.intensity,
        externalId: String(w.id),
      });
    });
}

/**
 * Verify an Oura webhook: HMAC-SHA256(clientSecret, timestamp + rawBody), hex, constant-time
 * compare, and timestamp skew ≤ 5 minutes.
 * @param {{ rawBody: string, signature?: string, timestamp?: string, clientSecret: string, now?: number }} p
 * @returns {boolean}
 */
export function verifyWebhookSignature({ rawBody, signature, timestamp, clientSecret, now = Date.now() }) {
  if (!signature || !timestamp || !clientSecret) return false;
  const tsMs = parseTimestamp(timestamp);
  if (tsMs === null || Math.abs(now - tsMs) > WEBHOOK_MAX_SKEW_SEC * 1000) return false;
  const expected = createHmac("sha256", clientSecret).update(timestamp + rawBody).digest();
  let given;
  try {
    given = Buffer.from(signature.trim(), "hex");
  } catch {
    return false;
  }
  if (given.length !== expected.length) return false;
  return timingSafeEqual(given, expected);
}

/** Accepts epoch seconds, epoch ms, or ISO-8601. */
function parseTimestamp(ts) {
  if (/^\d+$/.test(ts)) {
    const n = Number(ts);
    return n < 1e12 ? n * 1000 : n;
  }
  const ms = Date.parse(ts);
  return Number.isNaN(ms) ? null : ms;
}

/**
 * Subscription verification (GET /v1/webhooks/oura): echo `challenge` iff the token matches.
 * @param {{ verificationToken?: string, challenge?: string, expectedToken: string }} p
 * @returns {{ challenge: string } | null}
 */
export function verifySubscriptionChallenge({ verificationToken, challenge, expectedToken }) {
  if (!verificationToken || !challenge || !expectedToken) return null;
  const a = Buffer.from(verificationToken);
  const b = Buffer.from(expectedToken);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  return { challenge };
}

/**
 * Create a webhook subscription (run once per data type at setup; see README).
 * @param {{ fetch?: typeof fetch, clientId: string, clientSecret: string, callbackUrl: string, verificationToken: string, eventType: "create"|"update"|"delete", dataType: string }} p
 */
export async function createWebhookSubscription({ fetch: fetchImpl = globalThis.fetch, clientId, clientSecret, callbackUrl, verificationToken, eventType, dataType }) {
  const res = await fetchImpl(`${OURA_API_BASE}/webhook/subscription`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-client-id": clientId, "x-client-secret": clientSecret },
    body: JSON.stringify({ callback_url: callbackUrl, verification_token: verificationToken, event_type: eventType, data_type: dataType }),
  });
  if (!res.ok) throw new OuraError("upstream", `Webhook subscription failed (${res.status})`, res.status);
  return res.json();
}
