/**
 * S3 media store (schema §2.4).
 *
 * Lifecycle note: S3 lifecycle filters cannot wildcard the `<sub>` path segment, so retention is
 * driven by object tags set at upload time: meal photos carry `retention=meal-30d` (expired after
 * 30 days), exports carry `retention=export-7d` (7 days). Pinning a photo replaces the tag set
 * with `pinned=true`, which removes it from the expiry rule.
 */
import { ApiError } from "./http.js";

export const MAX_PHOTO_BYTES = 8 * 1024 * 1024;
export const PHOTO_CONTENT_TYPE = "image/jpeg";
export const MEAL_RETENTION_TAG = "retention=meal-30d";
export const EXPORT_RETENTION_TAG = "retention=export-7d";

/** @param {string} sub @param {string} mealId */
export const mealPhotoKey = (sub, mealId) => `users/${sub}/meals/${mealId}.jpg`;
/** @param {string} sub @param {string} ts */
export const exportKey = (sub, ts) => `users/${sub}/exports/${ts}.zip`;
/** @param {string} sub */
export const userPrefix = (sub) => `users/${sub}/`;

/**
 * Ensure a client-supplied photo key belongs to the caller (prevents cross-user reads).
 * @param {string} sub @param {string} key
 */
export function assertOwnPhotoKey(sub, key) {
  const re = new RegExp(`^users/${sub.replace(/[^A-Za-z0-9-]/g, "")}/meals/[A-Za-z0-9-]{1,64}\\.jpg$`);
  if (typeof key !== "string" || !re.test(key)) throw new ApiError("FORBIDDEN", "photoKey does not belong to caller");
}

/**
 * @typedef {Object} MediaStore
 * @property {(p: { key: string, contentType: string, contentLength?: number, expiresIn?: number, tagging?: string }) => Promise<{ url: string, headers: Record<string,string> }>} presignPut
 * @property {(p: { key: string, expiresIn?: number }) => Promise<string>} presignGet
 * @property {(key: string, opts?: { maxBytes?: number }) => Promise<Buffer>} getObjectBytes
 * @property {(p: { key: string, body: Buffer, contentType: string, tagging?: string }) => Promise<void>} putObject
 * @property {(key: string, tags: Record<string,string>) => Promise<void>} setTags
 * @property {(key: string) => Promise<void>} deleteObject
 * @property {(prefix: string) => Promise<number>} deletePrefix
 */

/**
 * Real S3 media store (lazy SDK import).
 * @param {{ bucket: string, kmsKeyId?: string }} opts
 * @returns {Promise<MediaStore>}
 */
export async function createMediaStore({ bucket, kmsKeyId }) {
  const s3 = await import("@aws-sdk/client-s3");
  const { getSignedUrl } = await import("@aws-sdk/s3-request-presigner");
  const client = new s3.S3Client({});
  const sse = kmsKeyId ? { ServerSideEncryption: "aws:kms", SSEKMSKeyId: kmsKeyId } : {};

  return {
    async presignPut({ key, contentType, contentLength, expiresIn = 300, tagging }) {
      if (contentType !== PHOTO_CONTENT_TYPE) throw new ApiError("VALIDATION_ERROR", "contentType must be image/jpeg");
      if (contentLength !== undefined && (contentLength <= 0 || contentLength > MAX_PHOTO_BYTES)) {
        throw new ApiError("PAYLOAD_TOO_LARGE", "Photo exceeds 8 MB");
      }
      const cmd = new s3.PutObjectCommand({
        Bucket: bucket, Key: key, ContentType: contentType,
        ...(contentLength !== undefined ? { ContentLength: contentLength } : {}),
        ...(tagging ? { Tagging: tagging } : {}),
        ...sse,
      });
      // Signing these headers means the client must send exactly these values.
      const signableHeaders = new Set(["content-type", "x-amz-tagging", "x-amz-server-side-encryption", "x-amz-server-side-encryption-aws-kms-key-id"]);
      if (contentLength !== undefined) signableHeaders.add("content-length");
      const url = await getSignedUrl(client, cmd, { expiresIn, signableHeaders, unhoistableHeaders: new Set(["x-amz-tagging", "x-amz-server-side-encryption", "x-amz-server-side-encryption-aws-kms-key-id"]) });
      const headers = { "Content-Type": contentType };
      if (tagging) headers["x-amz-tagging"] = tagging;
      if (kmsKeyId) {
        headers["x-amz-server-side-encryption"] = "aws:kms";
        headers["x-amz-server-side-encryption-aws-kms-key-id"] = kmsKeyId;
      }
      if (contentLength !== undefined) headers["Content-Length"] = String(contentLength);
      return { url, headers };
    },

    async presignGet({ key, expiresIn = 900 }) {
      return getSignedUrl(client, new s3.GetObjectCommand({ Bucket: bucket, Key: key }), { expiresIn });
    },

    async getObjectBytes(key, { maxBytes = MAX_PHOTO_BYTES } = {}) {
      let res;
      try {
        res = await client.send(new s3.GetObjectCommand({ Bucket: bucket, Key: key }));
      } catch (err) {
        if (err?.name === "NoSuchKey" || err?.$metadata?.httpStatusCode === 404) throw new ApiError("NOT_FOUND", "Photo not found");
        throw err;
      }
      if ((res.ContentLength ?? 0) > maxBytes) throw new ApiError("PAYLOAD_TOO_LARGE", "Photo exceeds size limit");
      const bytes = Buffer.from(await res.Body.transformToByteArray());
      if (bytes.length > maxBytes) throw new ApiError("PAYLOAD_TOO_LARGE", "Photo exceeds size limit");
      return bytes;
    },

    async putObject({ key, body, contentType, tagging }) {
      await client.send(new s3.PutObjectCommand({ Bucket: bucket, Key: key, Body: body, ContentType: contentType, ...(tagging ? { Tagging: tagging } : {}), ...sse }));
    },

    async setTags(key, tags) {
      await client.send(new s3.PutObjectTaggingCommand({
        Bucket: bucket, Key: key,
        Tagging: { TagSet: Object.entries(tags).map(([Key, Value]) => ({ Key, Value })) },
      }));
    },

    async deleteObject(key) {
      await client.send(new s3.DeleteObjectCommand({ Bucket: bucket, Key: key }));
    },

    async deletePrefix(prefix) {
      let deleted = 0;
      let ContinuationToken;
      do {
        const page = await client.send(new s3.ListObjectsV2Command({ Bucket: bucket, Prefix: prefix, ContinuationToken }));
        const objects = (page.Contents ?? []).map((o) => ({ Key: o.Key }));
        if (objects.length) {
          const res = await client.send(new s3.DeleteObjectsCommand({ Bucket: bucket, Delete: { Objects: objects, Quiet: true } }));
          if (res.Errors?.length) throw new Error(`Failed to delete ${res.Errors.length} objects`);
          deleted += objects.length;
        }
        ContinuationToken = page.IsTruncated ? page.NextContinuationToken : undefined;
      } while (ContinuationToken);
      return deleted;
    },
  };
}
