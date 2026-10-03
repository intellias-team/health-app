/**
 * Shared test fakes: repository on the in-memory DynamoDB, fetch, Claude client, media store,
 * KMS, API Gateway events.
 */
import { createCatalogStore, createRepository } from "../../src/lib/db.js";
import { createFakeDocClient } from "./fakeDynamo.js";

export const SUB = "11111111-2222-3333-4444-555555555555";
export const OTHER_SUB = "99999999-8888-7777-6666-555555555555";

/** Mutable clock. */
export function createClock(iso = "2026-10-03T12:00:00.000Z") {
  let t = Date.parse(iso);
  const now = () => t;
  now.set = (s) => (t = Date.parse(s));
  now.advance = (ms) => (t += ms);
  return now;
}

export function createTestRepo(now = createClock()) {
  const doc = createFakeDocClient();
  const repo = createRepository({ doc, tableName: "HealthAppData", now });
  const catalog = createCatalogStore({ doc, tableName: "HealthAppFoodCatalog", now });
  return { doc, repo, catalog, now };
}

/** API Gateway HTTP API v2 event. */
export function apiEvent({ method = "GET", path, body, query, headers = {}, sub = SUB, rawBody }) {
  return {
    version: "2.0",
    rawPath: path,
    headers: { "content-type": "application/json", ...headers },
    queryStringParameters: query,
    body: rawBody ?? (body === undefined ? undefined : JSON.stringify(body)),
    isBase64Encoded: false,
    requestContext: {
      http: { method, path },
      ...(sub ? { authorizer: { jwt: { claims: { sub } } } } : {}),
    },
  };
}

export const parse = (res) => ({ status: res.statusCode, body: res.body ? JSON.parse(res.body) : undefined, headers: res.headers });

/**
 * Fake fetch routing by URL substring → handler(url, init) returning { status, json }.
 * @param {[string|RegExp, (url: string, init: any) => any][]} routes
 */
export function createFakeFetch(routes) {
  const calls = [];
  const fetch = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    for (const [match, handler] of routes) {
      if (typeof match === "string" ? String(url).includes(match) : match.test(String(url))) {
        const r = await handler(String(url), init);
        const status = r?.status ?? 200;
        return { ok: status >= 200 && status < 300, status, json: async () => r?.json ?? {} };
      }
    }
    return { ok: false, status: 404, json: async () => ({}) };
  };
  fetch.calls = calls;
  return fetch;
}

/**
 * Fake Claude client: returns queued responses in order and records requests.
 * @param {any[]} responses Message-shaped objects ({ stop_reason, content, stop_details? })
 */
export function createFakeClaude(responses) {
  const requests = [];
  const queue = [...responses];
  return {
    requests,
    messages: {
      async create(params) {
        requests.push(structuredClone(params));
        const next = queue.shift();
        if (!next) throw new Error("fake claude: no more responses");
        if (next instanceof Error) throw next;
        return typeof next === "function" ? next(params) : next;
      },
    },
  };
}

/** Text response helper. */
export const textResponse = (text, stop_reason = "end_turn") => ({
  id: "msg_fake", type: "message", role: "assistant", stop_reason, stop_details: null,
  content: [{ type: "thinking", thinking: "", signature: "sig" }, { type: "text", text }],
});

/** Minimal JPEG bytes (magic header + padding). */
export const JPEG_BYTES = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 1)]);

/** In-memory media store. */
export function createFakeMedia(objects = {}) {
  const store = new Map(Object.entries(objects));
  const tags = new Map();
  return {
    store,
    tags,
    async presignPut({ key, contentType, tagging }) {
      return { url: `https://s3.example/${key}?signed`, headers: { "Content-Type": contentType, "x-amz-tagging": tagging } };
    },
    async presignGet({ key }) {
      return `https://s3.example/${key}?get`;
    },
    async getObjectBytes(key, { maxBytes = Infinity } = {}) {
      if (!store.has(key)) {
        const { ApiError } = await import("../../src/lib/http.js");
        throw new ApiError("NOT_FOUND", "Photo not found");
      }
      const b = store.get(key);
      if (b.length > maxBytes) {
        const { ApiError } = await import("../../src/lib/http.js");
        throw new ApiError("PAYLOAD_TOO_LARGE", "too big");
      }
      return b;
    },
    async putObject({ key, body }) {
      store.set(key, body);
    },
    async setTags(key, t) {
      tags.set(key, t);
    },
    async deleteObject(key) {
      store.delete(key);
    },
    async deletePrefix(prefix) {
      let n = 0;
      for (const key of [...store.keys()]) if (key.startsWith(prefix)) {
        store.delete(key);
        n++;
      }
      return n;
    },
  };
}

/** Fake KMS adapter with a fixed data key. */
export function createFakeKms() {
  const key = Buffer.alloc(32, 7);
  return {
    async generateDataKey({ EncryptionContext }) {
      return { Plaintext: Buffer.from(key), CiphertextBlob: Buffer.from(`wrapped:${EncryptionContext.sub}`) };
    },
    async decrypt({ CiphertextBlob, EncryptionContext }) {
      if (Buffer.from(CiphertextBlob).toString() !== `wrapped:${EncryptionContext.sub}`) throw new Error("InvalidCiphertextException");
      return { Plaintext: Buffer.from(key) };
    },
  };
}

/** USDA fake: in-memory foods keyed by search phrase keywords. */
export function createFakeUsda(foods) {
  const calls = { search: [], getFood: [] };
  return {
    calls,
    async search(q, opts = {}) {
      calls.search.push([q, opts]);
      const ql = q.toLowerCase();
      return foods.filter((f) => f.keywords.some((k) => ql.includes(k))).map(({ keywords, portions, ...f }) => f).slice(0, opts.limit ?? 25);
    },
    async getFood(id) {
      calls.getFood.push(id);
      const f = foods.find((x) => x.foodRef.id === String(id));
      if (!f) return undefined;
      const { keywords, ...rest } = f;
      return { portions: [], ...rest };
    },
    async lookupGtin() {
      return undefined;
    },
  };
}

export const RICE = { foodRef: { db: "usda", id: "169757" }, name: "Rice, white, cooked", keywords: ["rice"], nutrientsPer100g: { kcal: 130, proteinG: 2.7, carbsG: 28.2, fatG: 0.3, fiberG: 0.4, sugarG: 0.1, sodiumMg: 1 } };
export const CHICKEN = { foodRef: { db: "usda", id: "171477" }, name: "Chicken breast, grilled", keywords: ["chicken"], nutrientsPer100g: { kcal: 165, proteinG: 31, carbsG: 0, fatG: 3.6, fiberG: 0, sugarG: 0, sodiumMg: 74 } };
export const BROCCOLI = { foodRef: { db: "usda", id: "170379" }, name: "Broccoli, steamed", keywords: ["broccoli"], nutrientsPer100g: { kcal: 35, proteinG: 2.4, carbsG: 7.2, fatG: 0.4, fiberG: 3.3, sugarG: 1.4, sodiumMg: 41 } };
export const EGG = { foodRef: { db: "usda", id: "748967" }, name: "Egg, whole, cooked", keywords: ["egg"], nutrientsPer100g: { kcal: 155, proteinG: 12.6, carbsG: 1.1, fatG: 10.6, fiberG: 0, sugarG: 1.1, sodiumMg: 124 } };
export const BREAD = { foodRef: { db: "usda", id: "172686" }, name: "Bread, whole wheat", keywords: ["bread", "toast"], nutrientsPer100g: { kcal: 252, proteinG: 12.4, carbsG: 42.7, fatG: 3.5, fiberG: 6, sugarG: 4.4, sodiumMg: 450 } };
export const COTTAGE = { foodRef: { db: "usda", id: "173417" }, name: "Cheese, cottage, lowfat 2%", keywords: ["cottage"], nutrientsPer100g: { kcal: 81, proteinG: 10.5, carbsG: 4.8, fatG: 2.3, fiberG: 0, sugarG: 4, sodiumMg: 308 }, portions: [] };
