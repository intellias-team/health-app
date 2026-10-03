/**
 * Production dependency wiring from environment variables. Everything is created lazily on first
 * invocation (and cached per container) so handler modules can be imported without AWS SDKs.
 *
 * Environment:
 *   TABLE_NAME, CATALOG_TABLE_NAME, MEDIA_BUCKET, TOKEN_KEY_ID, OURA_SECRET_ARN, USDA_SECRET_ARN,
 *   OURA_REDIRECT_URI, OURA_QUEUE_URL, PLATFORM_APPLICATION_ARN, BEDROCK_MODEL_ID, BEDROCK_REGION
 */
import { createCatalogStore, createDocClient, createRepository } from "./db.js";
import { createLogger } from "./logger.js";
import { createSecrets } from "./secrets.js";

const env = (name, required = true) => {
  const value = process.env[name];
  if (required && !value) throw new Error(`Missing environment variable ${name}`);
  return value;
};

const memo = new Map();
/** @template T @param {string} key @param {() => Promise<T>} factory @returns {Promise<T>} */
const once = (key, factory) => {
  if (!memo.has(key)) memo.set(key, factory().catch((e) => { memo.delete(key); throw e; }));
  return memo.get(key);
};

export const logger = createLogger();
export const secrets = createSecrets();

export const docClient = () => once("doc", createDocClient);

export const repository = () => once("repo", async () => createRepository({ doc: await docClient(), tableName: env("TABLE_NAME") }));

export const catalog = () => once("catalog", async () => createCatalogStore({ doc: await docClient(), tableName: env("CATALOG_TABLE_NAME") }));

export const mediaStore = () => once("media", async () => {
  const { createMediaStore } = await import("./s3.js");
  return createMediaStore({ bucket: env("MEDIA_BUCKET") });
});

export const tokenVault = () => once("vault", async () => {
  const { createKmsAdapter, createTokenVault } = await import("./kms.js");
  return createTokenVault({ kms: await createKmsAdapter(), keyId: env("TOKEN_KEY_ID") });
});

/** @returns {Promise<{ clientId: string, clientSecret: string, webhookVerificationToken: string }>} */
export const ouraSecret = () => secrets.getJson(env("OURA_SECRET_ARN"));

export const ouraClient = () => once("oura", async () => {
  const { createOuraClient } = await import("../services/oura.js");
  const s = await ouraSecret();
  return createOuraClient({ clientId: s.clientId, clientSecret: s.clientSecret, redirectUri: env("OURA_REDIRECT_URI", false) });
});

export const usdaClient = () => once("usda", async () => {
  const { createUsdaClient } = await import("../services/usda.js");
  return createUsdaClient({
    catalog: await catalog(),
    getApiKey: async () => {
      const raw = await secrets.getString(env("USDA_SECRET_ARN"));
      try {
        return JSON.parse(raw).apiKey ?? raw;
      } catch {
        return raw;
      }
    },
  });
});

export const offClient = () => once("off", async () => {
  const { createOpenFoodFactsClient } = await import("../services/openfoodfacts.js");
  return createOpenFoodFactsClient({ catalog: await catalog() });
});

export const claudeClient = () => once("claude", async () => {
  const { createClaudeClient } = await import("../services/ai/claude.js");
  return createClaudeClient();
});

export const pushAdapter = () => once("push", async () => {
  const { createPushAdapter } = await import("./messaging.js");
  return createPushAdapter({ platformApplicationArn: env("PLATFORM_APPLICATION_ARN", false) });
});

export const ouraQueue = () => once("queue", async () => {
  const { createQueue } = await import("./messaging.js");
  return createQueue({ queueUrl: env("OURA_QUEUE_URL") });
});

/**
 * Lazily build a handler from an async deps factory, caching it per container.
 * @param {(deps: any) => (event: any, ctx?: any) => Promise<any>} createHandler
 * @param {() => Promise<any>} buildDeps
 */
export function lazyHandler(createHandler, buildDeps) {
  let ready;
  return async (event, context) => {
    ready ??= buildDeps().then(createHandler).catch((e) => { ready = undefined; throw e; });
    return (await ready)(event, context);
  };
}
