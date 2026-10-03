/**
 * DynamoDB repository for `HealthAppData` and `HealthAppFoodCatalog`.
 *
 * The repository talks to a small "doc client" adapter (`get/put/update/delete/query/scan/batchWrite`
 * taking DocumentClient-style params). `createDocClient()` builds the real one lazily from
 * `@aws-sdk/lib-dynamodb`; tests inject an in-memory fake with the same surface.
 */
import { ApiError } from "./http.js";
import { gsi1Keys, SYNCABLE_TYPES, userPk } from "./keys.js";
import { ttlAfterDays } from "./dates.js";

/**
 * @typedef {Object} DocClient
 * @property {(p: any) => Promise<{ Item?: any }>} get
 * @property {(p: any) => Promise<any>} put
 * @property {(p: any) => Promise<{ Attributes?: any }>} update
 * @property {(p: any) => Promise<any>} delete
 * @property {(p: any) => Promise<{ Items: any[], LastEvaluatedKey?: any }>} query
 * @property {(p: any) => Promise<{ Items: any[], LastEvaluatedKey?: any }>} scan
 * @property {(p: any) => Promise<{ UnprocessedItems?: any }>} batchWrite
 */

/**
 * Real DynamoDB DocumentClient adapter. AWS SDK is imported lazily so pure modules and tests
 * never need it.
 * @returns {Promise<DocClient>}
 */
export async function createDocClient() {
  const { DynamoDBClient } = await import("@aws-sdk/client-dynamodb");
  const lib = await import("@aws-sdk/lib-dynamodb");
  const client = lib.DynamoDBDocumentClient.from(new DynamoDBClient({}), {
    marshallOptions: { removeUndefinedValues: true, convertClassInstanceToMap: false },
  });
  return {
    get: (p) => client.send(new lib.GetCommand(p)),
    put: (p) => client.send(new lib.PutCommand(p)),
    update: (p) => client.send(new lib.UpdateCommand(p)),
    delete: (p) => client.send(new lib.DeleteCommand(p)),
    query: (p) => client.send(new lib.QueryCommand(p)),
    scan: (p) => client.send(new lib.ScanCommand(p)),
    batchWrite: (p) => client.send(new lib.BatchWriteCommand(p)),
  };
}

/** Thrown when an optimistic-concurrency check fails. Carries the current server item. */
export class VersionConflictError extends ApiError {
  /** @param {any} serverItem */
  constructor(serverItem) {
    super("CONFLICT", "Version conflict", { details: { serverVersion: serverItem?.version ?? 0 } });
    this.serverItem = serverItem;
  }
}

/** Attributes the server owns; never accepted from clients and stripped from API output. */
export const RESERVED_ATTRS = new Set([
  "PK", "SK", "GSI1PK", "GSI1SK", "GSI2PK", "GSI2SK", "entityType", "version", "updatedAt", "deleted",
  "expiresAt", "tokenCiphertext",
]);

const TOMBSTONE_TTL_DAYS = 90;

/** True for DynamoDB conditional failures from either the real SDK or the fake. */
export const isConditionalFailure = (err) => err?.name === "ConditionalCheckFailedException";

/**
 * Strip server/internal attributes for API responses. Keeps entity fields + id/version/updatedAt.
 * @param {any} item
 */
export function toPublic(item) {
  if (!item) return item;
  const out = {};
  for (const [k, v] of Object.entries(item)) {
    if (k === "PK" || k === "SK" || k.startsWith("GSI") || k === "tokenCiphertext" || k === "expiresAt") continue;
    out[k] = v;
  }
  return out;
}

/** Remove reserved attributes from client-supplied data. */
export function stripReserved(data) {
  const out = {};
  for (const [k, v] of Object.entries(data ?? {})) if (!RESERVED_ATTRS.has(k)) out[k] = v;
  return out;
}

/**
 * Repository over `HealthAppData`.
 * @param {{ doc: DocClient, tableName: string, now?: () => number }} opts
 */
export function createRepository({ doc, tableName, now = () => Date.now() }) {
  const iso = () => new Date(now()).toISOString();

  /** @param {{PK:string,SK:string}} key */
  async function get(key, { includeDeleted = false } = {}) {
    const { Item } = await doc.get({ TableName: tableName, Key: { PK: key.PK, SK: key.SK }, ConsistentRead: true });
    if (!Item || (!includeDeleted && Item.deleted)) return undefined;
    return Item;
  }

  /**
   * Versioned upsert with optimistic concurrency:
   * `attribute_not_exists(PK) OR version = :expected`.
   *
   * - `expectedVersion` given → must equal the stored version (0 = "I believe it doesn't exist").
   * - `expectedVersion` undefined → last-writer-wins upsert (reads the current version first and
   *   still uses a conditional write so concurrent writers retry instead of clobbering).
   *
   * Stamps `updatedAt`, `version`, `deleted:false` and, for syncable types, GSI1 change-feed keys.
   *
   * @param {string} sub
   * @param {{PK:string,SK:string}} key
   * @param {string} entityType
   * @param {string} id
   * @param {Record<string, any>} attrs     entity fields (reserved attrs are ignored unless `system`)
   * @param {{ expectedVersion?: number, extra?: Record<string, any>, retries?: number }} [opts]
   *        `extra` are trusted server attributes (e.g. tokenCiphertext, GSI2 keys, expiresAt).
   * @returns {Promise<any>} the stored item
   */
  async function putVersioned(sub, key, entityType, id, attrs, opts = {}) {
    let expected = opts.expectedVersion;
    let attempts = opts.retries ?? 3;
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const lww = expected === undefined;
      let base = expected;
      if (lww) {
        const current = await get(key, { includeDeleted: true });
        base = current?.version ?? 0;
      }
      const updatedAt = iso();
      const item = {
        ...stripReserved(attrs),
        ...(opts.extra ?? {}),
        PK: key.PK,
        SK: key.SK,
        entityType,
        id,
        updatedAt,
        version: base + 1,
        deleted: false,
      };
      if (SYNCABLE_TYPES.has(entityType)) Object.assign(item, gsi1Keys(sub, updatedAt, entityType, id));
      try {
        await doc.put({
          TableName: tableName,
          Item: item,
          ConditionExpression: "attribute_not_exists(PK) OR #v = :expected",
          ExpressionAttributeNames: { "#v": "version" },
          ExpressionAttributeValues: { ":expected": base },
        });
        return item;
      } catch (err) {
        if (!isConditionalFailure(err)) throw err;
        if (lww && --attempts > 0) continue;
        throw new VersionConflictError(await get(key, { includeDeleted: true }));
      }
    }
  }

  /**
   * Replace an item with a tombstone (keeps key fields, drops content). Tombstones stay in the
   * GSI1 change feed so other devices learn about the delete, and expire after 90 days.
   * @param {string} sub @param {{PK:string,SK:string}} key @param {string} entityType @param {string} id
   * @param {{ expectedVersion?: number, keep?: Record<string, any> }} [opts]
   */
  async function tombstone(sub, key, entityType, id, opts = {}) {
    const current = await get(key, { includeDeleted: true });
    if (!current) {
      if (opts.expectedVersion !== undefined && opts.expectedVersion !== 0) throw new VersionConflictError(undefined);
      return undefined;
    }
    if (current.deleted) return current;
    const base = opts.expectedVersion ?? current.version ?? 0;
    const updatedAt = iso();
    const item = {
      ...(opts.keep ?? {}),
      PK: key.PK,
      SK: key.SK,
      entityType,
      id,
      updatedAt,
      version: base + 1,
      deleted: true,
      expiresAt: ttlAfterDays(now(), TOMBSTONE_TTL_DAYS),
    };
    if (current.date) item.date = current.date;
    if (SYNCABLE_TYPES.has(entityType)) Object.assign(item, gsi1Keys(sub, updatedAt, entityType, id));
    try {
      await doc.put({
        TableName: tableName,
        Item: item,
        ConditionExpression: "attribute_not_exists(PK) OR #v = :expected",
        ExpressionAttributeNames: { "#v": "version" },
        ExpressionAttributeValues: { ":expected": base },
      });
      return item;
    } catch (err) {
      if (!isConditionalFailure(err)) throw err;
      throw new VersionConflictError(await get(key, { includeDeleted: true }));
    }
  }

  /** Unversioned put for non-syncable items (analysis jobs, chat, OAuth state, logs). */
  async function putRaw(item, { ifNotExists = false } = {}) {
    await doc.put({
      TableName: tableName,
      Item: item,
      ...(ifNotExists ? { ConditionExpression: "attribute_not_exists(PK)" } : {}),
    });
    return item;
  }

  /** Delete one item; with `mustExist`, throws ConditionalCheckFailed if absent. */
  async function deleteRaw(key, { mustExist = false, returnOld = false } = {}) {
    const res = await doc.delete({
      TableName: tableName,
      Key: { PK: key.PK, SK: key.SK },
      ...(mustExist ? { ConditionExpression: "attribute_exists(PK)" } : {}),
      ...(returnOld ? { ReturnValues: "ALL_OLD" } : {}),
    });
    return res?.Attributes;
  }

  /** Run a query to completion (or until `limit` items). */
  async function queryAll(params, limit = Infinity) {
    const items = [];
    let ExclusiveStartKey;
    do {
      const res = await doc.query({ TableName: tableName, ...params, ExclusiveStartKey });
      items.push(...(res.Items ?? []));
      ExclusiveStartKey = res.LastEvaluatedKey;
    } while (ExclusiveStartKey && items.length < limit);
    return items.slice(0, limit);
  }

  /**
   * Items whose SK is between `from` and `to` (inclusive), excluding tombstones by default.
   * @param {{PK:string, from:string, to:string}} range
   */
  async function queryRange(range, { includeDeleted = false, descending = false, limit } = {}) {
    const items = await queryAll(
      {
        KeyConditionExpression: "PK = :pk AND SK BETWEEN :from AND :to",
        ExpressionAttributeValues: { ":pk": range.PK, ":from": range.from, ":to": range.to },
        ScanIndexForward: !descending,
      },
      limit,
    );
    return includeDeleted ? items : items.filter((i) => !i.deleted);
  }

  /** Items whose SK begins with `prefix`. @param {{PK:string, prefix:string}} p */
  async function queryPrefix(p, { includeDeleted = false, descending = false, limit } = {}) {
    const items = await queryAll(
      {
        KeyConditionExpression: "PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues: { ":pk": p.PK, ":prefix": p.prefix },
        ScanIndexForward: !descending,
      },
      limit,
    );
    return includeDeleted ? items : items.filter((i) => !i.deleted);
  }

  /**
   * Sync change feed: items with `GSI1SK > since`, oldest first.
   * @param {string} sub @param {string} since  last GSI1SK seen ("" = from beginning) @param {number} limit
   * @returns {Promise<{ items: any[], hasMore: boolean }>}
   */
  async function queryChanges(sub, since, limit) {
    const items = [];
    let ExclusiveStartKey;
    do {
      const res = await doc.query({
        TableName: tableName,
        IndexName: "GSI1",
        KeyConditionExpression: "GSI1PK = :pk AND GSI1SK > :since",
        ExpressionAttributeValues: { ":pk": userPk(sub), ":since": since || "UPD#" },
        ScanIndexForward: true,
        Limit: limit + 1 - items.length,
        ExclusiveStartKey,
      });
      items.push(...(res.Items ?? []));
      ExclusiveStartKey = res.LastEvaluatedKey;
    } while (ExclusiveStartKey && items.length <= limit);
    return { items: items.slice(0, limit), hasMore: items.length > limit };
  }

  /** Query GSI2 by partition key. */
  async function queryGsi2(gsi2pk) {
    return queryAll({
      IndexName: "GSI2",
      KeyConditionExpression: "GSI2PK = :pk",
      ExpressionAttributeValues: { ":pk": gsi2pk },
    });
  }

  /**
   * Page through the sparse GSI2 index (connections + push devices) and call `onItem` for items
   * whose GSI2PK starts with `prefix`.
   */
  async function scanGsi2(prefix, onItem) {
    let ExclusiveStartKey;
    do {
      const res = await doc.scan({ TableName: tableName, IndexName: "GSI2", ExclusiveStartKey });
      for (const item of res.Items ?? []) if (String(item.GSI2PK ?? "").startsWith(prefix)) await onItem(item);
      ExclusiveStartKey = res.LastEvaluatedKey;
    } while (ExclusiveStartKey);
  }

  /** Every item key in the user's partition (for export/delete). */
  async function listUserItems(sub) {
    return queryAll({
      KeyConditionExpression: "PK = :pk",
      ExpressionAttributeValues: { ":pk": userPk(sub) },
    });
  }

  /** Batched delete (25 per request) with retry of unprocessed items. */
  async function batchDelete(keys) {
    let deleted = 0;
    for (let i = 0; i < keys.length; i += 25) {
      let requests = keys.slice(i, i + 25).map((k) => ({ DeleteRequest: { Key: { PK: k.PK, SK: k.SK } } }));
      for (let attempt = 0; requests.length > 0; attempt++) {
        if (attempt > 6) throw new Error("batchDelete: unprocessed items remain after retries");
        if (attempt > 0) await new Promise((r) => setTimeout(r, 2 ** attempt * 25));
        const res = await doc.batchWrite({ RequestItems: { [tableName]: requests } });
        const unprocessed = res?.UnprocessedItems?.[tableName] ?? [];
        deleted += requests.length - unprocessed.length;
        requests = unprocessed;
      }
    }
    return deleted;
  }

  /**
   * Atomic counter increment with an upper bound (used for AI rate limiting).
   * @returns {Promise<number|null>} new count, or null when the bound was reached
   */
  async function incrementBounded(key, max, expiresAt) {
    try {
      const res = await doc.update({
        TableName: tableName,
        Key: { PK: key.PK, SK: key.SK },
        UpdateExpression: "SET #e = if_not_exists(#e, :exp) ADD #c :one",
        ConditionExpression: "attribute_not_exists(#c) OR #c < :max",
        ExpressionAttributeNames: { "#c": "count", "#e": "expiresAt" },
        ExpressionAttributeValues: { ":one": 1, ":max": max, ":exp": expiresAt },
        ReturnValues: "ALL_NEW",
      });
      return res?.Attributes?.count ?? null;
    } catch (err) {
      if (isConditionalFailure(err)) return null;
      throw err;
    }
  }

  /** Partial attribute update without versioning (system bookkeeping, e.g. lastSyncAt). */
  async function patch(key, attrs, { mustExist = true } = {}) {
    const names = {};
    const values = {};
    const sets = Object.entries(attrs).filter(([, v]) => v !== undefined).map(([k, v], i) => {
      names[`#a${i}`] = k;
      values[`:a${i}`] = v;
      return `#a${i} = :a${i}`;
    });
    const removes = Object.entries(attrs).filter(([, v]) => v === undefined).map(([k], i) => {
      names[`#r${i}`] = k;
      return `#r${i}`;
    });
    if (!sets.length && !removes.length) return undefined;
    const res = await doc.update({
      TableName: tableName,
      Key: { PK: key.PK, SK: key.SK },
      UpdateExpression: [sets.length ? `SET ${sets.join(", ")}` : "", removes.length ? `REMOVE ${removes.join(", ")}` : ""].filter(Boolean).join(" "),
      ...(mustExist ? { ConditionExpression: "attribute_exists(PK)" } : {}),
      ExpressionAttributeNames: names,
      ...(sets.length ? { ExpressionAttributeValues: values } : {}),
      ReturnValues: "ALL_NEW",
    });
    return res?.Attributes;
  }

  /**
   * Paged scan with a filter (used by the daily tombstone purge only).
   * @param {{ FilterExpression: string, ExpressionAttributeNames?: any, ExpressionAttributeValues?: any }} filter
   * @param {(items: any[]) => Promise<void>} onPage
   */
  async function scanFiltered(filter, onPage) {
    let ExclusiveStartKey;
    do {
      const res = await doc.scan({ TableName: tableName, ...filter, ExclusiveStartKey });
      if (res.Items?.length) await onPage(res.Items);
      ExclusiveStartKey = res.LastEvaluatedKey;
    } while (ExclusiveStartKey);
  }

  return {
    tableName, now, iso, get, putVersioned, tombstone, putRaw, deleteRaw, queryRange, queryPrefix,
    queryChanges, queryGsi2, scanGsi2, listUserItems, batchDelete, incrementBounded, patch, scanFiltered,
  };
}

/** @typedef {ReturnType<typeof createRepository>} Repository */

/**
 * Shared nutrition cache (`HealthAppFoodCatalog`). Contains no PII.
 * @param {{ doc: DocClient, tableName: string, now?: () => number }} opts
 */
export function createCatalogStore({ doc, tableName, now = () => Date.now() }) {
  return {
    /** @param {{PK:string,SK:string}} key */
    async get(key) {
      const { Item } = await doc.get({ TableName: tableName, Key: key });
      if (!Item) return undefined;
      if (Item.expiresAt && Item.expiresAt * 1000 < now()) return undefined; // TTL deletion can lag
      return Item;
    },
    /** @param {{PK:string,SK:string}} key @param {Record<string, any>} attrs @param {number} ttlDays */
    async put(key, attrs, ttlDays) {
      const item = { ...attrs, ...key, cachedAt: new Date(now()).toISOString(), expiresAt: ttlAfterDays(now(), ttlDays) };
      await doc.put({ TableName: tableName, Item: item });
      return item;
    },
  };
}

/** @typedef {ReturnType<typeof createCatalogStore>} CatalogStore */
