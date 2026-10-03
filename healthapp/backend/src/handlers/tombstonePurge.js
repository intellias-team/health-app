/**
 * tombstonePurge — EventBridge `rate(1 day)`.
 *
 * Backstop for TTL (TTL deletion can lag, and very old tombstones may predate the `expiresAt`
 * convention) plus orphaned-photo cleanup: meal tombstones from the last 2 days get their photo
 * object (`users/<sub>/meals/<mealId>.jpg`) deleted again in case the inline delete failed.
 */
import { mealPhotoKey } from "../lib/s3.js";
import * as d from "../lib/deps.js";

export const TOMBSTONE_RETENTION_DAYS = 90;
const PHOTO_RECHECK_DAYS = 2;

/**
 * @param {{ repo: import("../lib/db.js").Repository, media: Pick<import("../lib/s3.js").MediaStore, "deleteObject">, now?: () => number, logger?: any }} deps
 */
export function createHandler(deps) {
  const { repo, media } = deps;
  const logger = deps.logger ?? d.logger;
  const now = deps.now ?? (() => Date.now());

  return async function handler() {
    const purgeBefore = new Date(now() - TOMBSTONE_RETENTION_DAYS * 86_400_000).toISOString();
    const photoAfter = new Date(now() - PHOTO_RECHECK_DAYS * 86_400_000).toISOString();
    const summary = { purged: 0, photosDeleted: 0 };

    await repo.scanFiltered(
      {
        FilterExpression: "#d = :t",
        ExpressionAttributeNames: { "#d": "deleted" },
        ExpressionAttributeValues: { ":t": true },
      },
      async (items) => {
        const expired = items.filter((i) => i.updatedAt < purgeBefore);
        if (expired.length) summary.purged += await repo.batchDelete(expired);
        for (const i of items) {
          if (i.entityType !== "meal" || i.updatedAt < photoAfter || !String(i.PK).startsWith("USER#")) continue;
          try {
            await media.deleteObject(mealPhotoKey(i.PK.slice(5), i.id));
            summary.photosDeleted++;
          } catch (err) {
            logger.warn("orphan photo delete failed", { err });
          }
        }
      },
    );
    logger.info("tombstone purge", summary);
    return summary;
  };
}

export const handler = d.lazyHandler(createHandler, async () => ({ repo: await d.repository(), media: await d.mediaStore() }));
