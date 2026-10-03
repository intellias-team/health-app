/**
 * HTTP helpers for API Gateway HTTP API (payload format 2.0) Lambda handlers.
 *
 * - `sub` is taken ONLY from `event.requestContext.authorizer.jwt.claims.sub` (API §3.5).
 * - Errors are rendered as `{ error: { code, message, details } }` (API §3.1).
 */
import { timingSafeEqual } from "node:crypto";
import { createLogger, hashSub } from "./logger.js";

/** Error codes from the API contract, with their default HTTP status. */
export const ERROR_CODES = Object.freeze({
  VALIDATION_ERROR: 400,
  BAD_REQUEST: 400,
  UNAUTHORIZED: 401,
  FORBIDDEN: 403,
  NOT_FOUND: 404,
  CONFLICT: 409,
  PAYLOAD_TOO_LARGE: 413,
  UNPROCESSABLE: 422,
  AI_REFUSED: 422,
  RATE_LIMITED: 429,
  INTERNAL_ERROR: 500,
  UPSTREAM_ERROR: 502,
  AI_INCOMPLETE: 502,
});

/** Typed API error mapped to the contract's error envelope. */
export class ApiError extends Error {
  /**
   * @param {keyof typeof ERROR_CODES | string} code
   * @param {string} message
   * @param {{ status?: number, details?: Record<string, unknown>, headers?: Record<string,string> }} [opts]
   */
  constructor(code, message, opts = {}) {
    super(message);
    this.name = "ApiError";
    this.code = code;
    this.status = opts.status ?? ERROR_CODES[code] ?? 500;
    this.details = opts.details;
    this.headers = opts.headers;
  }
}

const MAX_BODY_BYTES = 1_000_000;

/**
 * @typedef {Object} Request
 * @property {string} method
 * @property {string} path
 * @property {Record<string,string>} params   path parameters
 * @property {Record<string,string>} query
 * @property {Record<string,string>} headers  lower-cased header names
 * @property {string} rawBody
 * @property {any} body                        parsed JSON (or undefined)
 * @property {string|undefined} sub            Cognito subject (undefined on public routes without JWT)
 * @property {any} event
 */

/**
 * Extract the Cognito `sub` claim. Never trust any other identity source.
 * @param {any} event
 * @returns {string|undefined}
 */
export function getSub(event) {
  const sub = event?.requestContext?.authorizer?.jwt?.claims?.sub;
  return typeof sub === "string" && sub.length > 0 ? sub : undefined;
}

/**
 * Parse an API Gateway HTTP API v2 event into a normalised request.
 * @param {any} event
 * @returns {Request}
 */
export function parseEvent(event) {
  const headers = {};
  for (const [k, v] of Object.entries(event?.headers ?? {})) headers[k.toLowerCase()] = String(v);
  let rawBody = event?.body ?? "";
  if (rawBody && event?.isBase64Encoded) rawBody = Buffer.from(rawBody, "base64").toString("utf8");
  if (Buffer.byteLength(rawBody, "utf8") > MAX_BODY_BYTES) {
    throw new ApiError("PAYLOAD_TOO_LARGE", "Request body too large");
  }
  let body;
  if (rawBody) {
    const ct = headers["content-type"] ?? "application/json";
    if (ct.includes("json")) {
      try {
        body = JSON.parse(rawBody);
      } catch {
        throw new ApiError("VALIDATION_ERROR", "Body is not valid JSON");
      }
    }
  }
  return {
    method: (event?.requestContext?.http?.method ?? event?.httpMethod ?? "GET").toUpperCase(),
    path: event?.rawPath ?? event?.requestContext?.http?.path ?? "/",
    params: { ...(event?.pathParameters ?? {}) },
    query: { ...(event?.queryStringParameters ?? {}) },
    headers,
    rawBody,
    body,
    sub: getSub(event),
    event,
  };
}

/**
 * JSON response.
 * @param {number} statusCode
 * @param {unknown} body
 * @param {Record<string,string>} [headers]
 */
export function json(statusCode, body, headers = {}) {
  return {
    statusCode,
    headers: { "content-type": "application/json", "cache-control": "no-store", ...headers },
    body: JSON.stringify(body),
  };
}

/** 204 No Content. */
export function noContent() {
  return { statusCode: 204, headers: { "cache-control": "no-store" }, body: "" };
}

/** 302 redirect. @param {string} location */
export function redirect(location) {
  return { statusCode: 302, headers: { location, "cache-control": "no-store" }, body: "" };
}

/**
 * Render an error as the contract envelope.
 * @param {unknown} err
 */
export function errorResponse(err) {
  if (err instanceof ApiError) {
    const error = { code: err.code, message: err.message };
    if (err.details) error.details = err.details;
    return json(err.status, { error }, err.headers);
  }
  return json(500, { error: { code: "INTERNAL_ERROR", message: "Internal server error" } });
}

/** Header CloudFront adds to every origin request (API §3.5). */
export const ORIGIN_VERIFY_HEADER = "x-origin-verify";

/**
 * Constant-time check that a request came through the CloudFront distribution.
 * @param {Record<string,string>} headers lower-cased
 * @param {string|undefined} secret  undefined/empty disables the check (local tests)
 */
export function isFromTrustedOrigin(headers, secret) {
  if (!secret) return true;
  const got = Buffer.from(headers[ORIGIN_VERIFY_HEADER] ?? "", "utf8");
  const want = Buffer.from(secret, "utf8");
  return got.length === want.length && timingSafeEqual(got, want);
}

/**
 * Compile a route template like `/v1/meals/{id}` into a matcher.
 * @param {string} template
 * @returns {(path: string) => Record<string,string> | null}
 */
export function compilePath(template) {
  const names = [];
  const pattern = template
    .split("/")
    .map((seg) => {
      const m = /^\{(\w+)\}$/.exec(seg);
      if (m) {
        names.push(m[1]);
        return "([^/]+)";
      }
      return seg.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    })
    .join("/");
  const re = new RegExp(`^${pattern}/?$`);
  return (path) => {
    const m = re.exec(path);
    if (!m) return null;
    const params = {};
    names.forEach((n, i) => (params[n] = decodeURIComponent(m[i + 1])));
    return params;
  };
}

/**
 * @typedef {Object} Route
 * @property {string} method
 * @property {string} path            template, e.g. `/v1/meals/{id}`
 * @property {boolean} [public]       if true, no `sub` required
 * @property {(req: Request) => Promise<any>} handler
 */

/**
 * Build an API Gateway Lambda handler from a route table. Static routes should be listed
 * before parameterised routes that could shadow them.
 *
 * @param {Route[]} routes
 * Requests that did not come through CloudFront (missing/wrong `x-origin-verify`) get 403 when
 * `opts.originSecret` (default: env ORIGIN_VERIFY_SECRET) is set.
 *
 * @param {{ logger?: ReturnType<typeof createLogger>, now?: () => number, originSecret?: string }} [opts]
 * @returns {(event: any, context?: any) => Promise<any>}
 */
export function createRouter(routes, opts = {}) {
  const logger = opts.logger ?? createLogger();
  const clock = opts.now ?? (() => Date.now());
  const compiled = routes.map((r) => ({ ...r, method: r.method.toUpperCase(), match: compilePath(r.path) }));
  const originSecret = "originSecret" in opts ? opts.originSecret : process.env.ORIGIN_VERIFY_SECRET;

  return async function route(event) {
    const started = clock();
    let status = 500;
    let routeKey = "unmatched";
    let sub;
    try {
      const req = parseEvent(event);
      sub = req.sub;
      if (!isFromTrustedOrigin(req.headers, originSecret)) {
        throw new ApiError("FORBIDDEN", "Use the public API endpoint");
      }
      let pathMatched = false;
      for (const r of compiled) {
        const params = r.match(req.path);
        if (!params) continue;
        pathMatched = true;
        if (r.method !== req.method) continue;
        routeKey = `${r.method} ${r.path}`;
        if (!r.public && !req.sub) throw new ApiError("UNAUTHORIZED", "Missing or invalid token");
        req.params = { ...req.params, ...params };
        const res = await r.handler(req);
        status = res?.statusCode ?? 200;
        return res;
      }
      throw pathMatched
        ? new ApiError("NOT_FOUND", "Method not allowed for this resource", { status: 405 })
        : new ApiError("NOT_FOUND", "Route not found");
    } catch (err) {
      const res = errorResponse(err);
      status = res.statusCode;
      if (status >= 500) logger.error("request failed", { route: routeKey, err });
      return res;
    } finally {
      logger.info("request", { route: routeKey, status, latencyMs: clock() - started, subHash: sub ? hashSub(sub) : undefined });
    }
  };
}

/**
 * Require a string query parameter.
 * @param {Request} req @param {string} name
 */
export function requireQuery(req, name) {
  const v = req.query[name];
  if (v === undefined || v === "") throw new ApiError("VALIDATION_ERROR", `Missing query parameter '${name}'`, { details: { field: name } });
  return v;
}
