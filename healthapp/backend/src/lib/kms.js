/**
 * Envelope encryption for OAuth tokens (schema §2.1: `tokenCiphertext`).
 *
 * A fresh 256-bit data key is generated per write with KMS `GenerateDataKey` under the token
 * CMK, bound to the user via encryption context `{ sub, purpose }`. The plaintext JSON is
 * encrypted locally with AES-256-GCM; only the KMS-wrapped data key is stored next to it.
 */
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

/**
 * @typedef {Object} KmsAdapter
 * @property {(p: { KeyId: string, KeySpec: "AES_256", EncryptionContext: Record<string,string> }) => Promise<{ Plaintext: Uint8Array, CiphertextBlob: Uint8Array }>} generateDataKey
 * @property {(p: { CiphertextBlob: Uint8Array, EncryptionContext: Record<string,string>, KeyId?: string }) => Promise<{ Plaintext: Uint8Array }>} decrypt
 */

/** Real KMS adapter (lazy SDK import). @returns {Promise<KmsAdapter>} */
export async function createKmsAdapter() {
  const { KMSClient, GenerateDataKeyCommand, DecryptCommand } = await import("@aws-sdk/client-kms");
  const client = new KMSClient({});
  return {
    generateDataKey: (p) => client.send(new GenerateDataKeyCommand(p)),
    decrypt: (p) => client.send(new DecryptCommand(p)),
  };
}

const PURPOSE = "oauth-token";

/**
 * @param {{ kms: KmsAdapter, keyId: string }} opts
 */
export function createTokenVault({ kms, keyId }) {
  return {
    /**
     * @param {string} sub @param {Record<string, unknown>} value
     * @returns {Promise<string>} opaque base64 envelope
     */
    async encrypt(sub, value) {
      const context = { sub, purpose: PURPOSE };
      const { Plaintext, CiphertextBlob } = await kms.generateDataKey({ KeyId: keyId, KeySpec: "AES_256", EncryptionContext: context });
      const dataKey = Buffer.from(Plaintext);
      try {
        const iv = randomBytes(12);
        const cipher = createCipheriv("aes-256-gcm", dataKey, iv);
        cipher.setAAD(Buffer.from(`${sub}:${PURPOSE}`));
        const ct = Buffer.concat([cipher.update(JSON.stringify(value), "utf8"), cipher.final()]);
        const envelope = {
          v: 1,
          k: Buffer.from(CiphertextBlob).toString("base64"),
          iv: iv.toString("base64"),
          tag: cipher.getAuthTag().toString("base64"),
          ct: ct.toString("base64"),
        };
        return Buffer.from(JSON.stringify(envelope)).toString("base64");
      } finally {
        dataKey.fill(0);
      }
    },

    /**
     * @param {string} sub @param {string} envelopeB64
     * @returns {Promise<any>}
     */
    async decrypt(sub, envelopeB64) {
      const env = JSON.parse(Buffer.from(envelopeB64, "base64").toString("utf8"));
      if (env.v !== 1) throw new Error("Unsupported token envelope version");
      const { Plaintext } = await kms.decrypt({
        CiphertextBlob: Buffer.from(env.k, "base64"),
        EncryptionContext: { sub, purpose: PURPOSE },
        KeyId: keyId,
      });
      const dataKey = Buffer.from(Plaintext);
      try {
        const decipher = createDecipheriv("aes-256-gcm", dataKey, Buffer.from(env.iv, "base64"));
        decipher.setAAD(Buffer.from(`${sub}:${PURPOSE}`));
        decipher.setAuthTag(Buffer.from(env.tag, "base64"));
        const pt = Buffer.concat([decipher.update(Buffer.from(env.ct, "base64")), decipher.final()]);
        return JSON.parse(pt.toString("utf8"));
      } finally {
        dataKey.fill(0);
      }
    },
  };
}

/** @typedef {ReturnType<typeof createTokenVault>} TokenVault */
