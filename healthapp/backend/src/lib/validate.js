/**
 * Tiny hand-written schema validation (no dependencies).
 *
 * A validator is a function `(value, path) => cleanedValue` that throws `ValidationIssue`.
 * Unknown object keys are dropped (never stored).
 *
 * @example
 *   const schema = v.object({ name: v.string({ max: 100 }), grams: v.optional(v.number({ min: 0 })) });
 *   const clean = validate(schema, req.body);
 */
import { ApiError } from "./http.js";
import { isDate } from "./dates.js";

class ValidationIssue extends Error {
  constructor(path, message) {
    super(message);
    this.path = path;
  }
}

/** @typedef {(value: any, path: string) => any} Validator */

const fail = (path, msg) => {
  throw new ValidationIssue(path || "(root)", msg);
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const ISO_TS_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d{1,9})?)?(Z|[+-]\d{2}:\d{2})$/;

export const v = {
  /** @param {{ min?: number, max?: number, pattern?: RegExp, enum?: readonly string[], trim?: boolean }} [o] @returns {Validator} */
  string(o = {}) {
    return (val, path) => {
      if (typeof val !== "string") fail(path, "must be a string");
      const s = o.trim === false ? val : val.trim();
      if (o.min !== undefined && s.length < o.min) fail(path, `must be at least ${o.min} characters`);
      if (s.length > (o.max ?? 10_000)) fail(path, `must be at most ${o.max ?? 10_000} characters`);
      if (o.pattern && !o.pattern.test(s)) fail(path, "has an invalid format");
      if (o.enum && !o.enum.includes(s)) fail(path, `must be one of ${o.enum.join(", ")}`);
      return s;
    };
  },
  /** @param {{ min?: number, max?: number, int?: boolean }} [o] @returns {Validator} */
  number(o = {}) {
    return (val, path) => {
      const n = typeof val === "string" && val.trim() !== "" ? Number(val) : val;
      if (typeof n !== "number" || !Number.isFinite(n)) fail(path, "must be a number");
      if (o.int && !Number.isInteger(n)) fail(path, "must be an integer");
      if (o.min !== undefined && n < o.min) fail(path, `must be >= ${o.min}`);
      if (o.max !== undefined && n > o.max) fail(path, `must be <= ${o.max}`);
      return n;
    };
  },
  /** @returns {Validator} */
  boolean() {
    return (val, path) => {
      if (typeof val !== "boolean") fail(path, "must be a boolean");
      return val;
    };
  },
  /** yyyy-mm-dd @returns {Validator} */
  date() {
    return (val, path) => {
      if (!isDate(val)) fail(path, "must be a date (yyyy-mm-dd)");
      return val;
    };
  },
  /** ISO-8601 timestamp, normalised to UTC `...Z`. @returns {Validator} */
  timestamp() {
    return (val, path) => {
      if (typeof val !== "string" || !ISO_TS_RE.test(val) || Number.isNaN(Date.parse(val))) fail(path, "must be an ISO-8601 timestamp");
      return new Date(val).toISOString();
    };
  },
  /** @returns {Validator} */
  uuid() {
    return (val, path) => {
      if (typeof val !== "string" || !UUID_RE.test(val)) fail(path, "must be a UUID");
      return val.toLowerCase();
    };
  },
  /** Opaque identifier safe for use in keys. @returns {Validator} */
  id(max = 64) {
    return v.string({ min: 1, max, pattern: /^[A-Za-z0-9_.:-]+$/ });
  },
  /** @param {Validator} item @param {{ min?: number, max?: number }} [o] @returns {Validator} */
  array(item, o = {}) {
    return (val, path) => {
      if (!Array.isArray(val)) fail(path, "must be an array");
      if (o.min !== undefined && val.length < o.min) fail(path, `must contain at least ${o.min} items`);
      if (val.length > (o.max ?? 1000)) fail(path, `must contain at most ${o.max ?? 1000} items`);
      return val.map((x, i) => item(x, `${path}[${i}]`));
    };
  },
  /** @param {Record<string, Validator>} shape @returns {Validator} */
  object(shape) {
    return (val, path) => {
      if (val === null || typeof val !== "object" || Array.isArray(val)) fail(path, "must be an object");
      const out = {};
      for (const [k, validator] of Object.entries(shape)) {
        const r = validator(val[k], path ? `${path}.${k}` : k);
        if (r !== undefined) out[k] = r;
      }
      return out;
    };
  },
  /** Map with validated values and keys limited to `keys` (if given). @returns {Validator} */
  record(valueValidator, { keys, maxKeys = 100 } = {}) {
    return (val, path) => {
      if (val === null || typeof val !== "object" || Array.isArray(val)) fail(path, "must be an object");
      const entries = Object.entries(val);
      if (entries.length > maxKeys) fail(path, "has too many keys");
      const out = {};
      for (const [k, x] of entries) {
        if (keys && !keys.includes(k)) continue;
        if (x === null || x === undefined) continue;
        out[k] = valueValidator(x, `${path}.${k}`);
      }
      return out;
    };
  },
  /** @param {Validator} inner @returns {Validator} */
  optional(inner) {
    return (val, path) => (val === undefined || val === null ? undefined : inner(val, path));
  },
  /** @param {Validator} inner @param {any} def @returns {Validator} */
  default(inner, def) {
    return (val, path) => (val === undefined || val === null ? def : inner(val, path));
  },
  /** Accept anything JSON-ish (bounded size). @returns {Validator} */
  any({ maxBytes = 20_000 } = {}) {
    return (val, path) => {
      if (val === undefined) return undefined;
      if (JSON.stringify(val).length > maxBytes) fail(path, "is too large");
      return val;
    };
  },
};

/**
 * Validate and clean `value`; throws ApiError(VALIDATION_ERROR) with `details.path`.
 * @template T
 * @param {Validator} schema @param {unknown} value @param {string} [path]
 * @returns {any}
 */
export function validate(schema, value, path = "") {
  try {
    return schema(value, path);
  } catch (err) {
    if (err instanceof ValidationIssue) {
      throw new ApiError("VALIDATION_ERROR", `${err.path} ${err.message}`, { details: { path: err.path } });
    }
    throw err;
  }
}
