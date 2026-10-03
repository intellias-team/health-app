/**
 * Secrets Manager reader with a 5-minute in-memory cache (per Lambda container).
 */

/**
 * @param {{ fetchSecret?: (id: string) => Promise<string>, ttlMs?: number, now?: () => number }} [opts]
 */
export function createSecrets(opts = {}) {
  const ttlMs = opts.ttlMs ?? 5 * 60_000;
  const now = opts.now ?? (() => Date.now());
  const cache = new Map();
  let fetchSecret = opts.fetchSecret;

  async function defaultFetch(id) {
    const { SecretsManagerClient, GetSecretValueCommand } = await import("@aws-sdk/client-secrets-manager");
    const client = new SecretsManagerClient({});
    fetchSecret = async (secretId) => (await client.send(new GetSecretValueCommand({ SecretId: secretId }))).SecretString ?? "";
    return fetchSecret(id);
  }

  return {
    /** @param {string} id @returns {Promise<string>} */
    async getString(id) {
      const hit = cache.get(id);
      if (hit && hit.expires > now()) return hit.value;
      const value = await (fetchSecret ?? defaultFetch)(id);
      cache.set(id, { value, expires: now() + ttlMs });
      return value;
    },
    /** @param {string} id @returns {Promise<any>} */
    async getJson(id) {
      return JSON.parse(await this.getString(id));
    },
  };
}
