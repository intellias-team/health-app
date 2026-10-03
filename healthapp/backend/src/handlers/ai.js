/**
 * aiFn — /v1/photos/upload-url, /v1/ai/meal-analysis, /v1/ai/voice-parse, /v1/ai/coach
 *
 * Prompts contain only the photo / transcript / the user's own health data — never name, email or
 * Apple ID (API §3.5).
 */
import { ApiError, createRouter, json } from "../lib/http.js";
import { validate, v } from "../lib/validate.js";
import { consumeAiQuota } from "../lib/ratelimit.js";
import { mealPhotoKey, MAX_PHOTO_BYTES, MEAL_RETENTION_TAG, PHOTO_CONTENT_TYPE } from "../lib/s3.js";
import { MEAL_CATEGORIES } from "../lib/schemas.js";
import { ClaudeError } from "../services/ai/claude.js";
import { analyzeMealPhoto } from "../services/ai/mealRecognition.js";
import { parseVoiceLog } from "../services/ai/voiceParse.js";
import { runCoachTurn } from "../services/ai/coach.js";
import { createUserData } from "../services/userData.js";
import * as d from "../lib/deps.js";

const uploadSchema = v.object({
  mealId: v.uuid(),
  contentType: v.string({ enum: [PHOTO_CONTENT_TYPE] }),
  contentLength: v.optional(v.number({ int: true, min: 1, max: MAX_PHOTO_BYTES })),
});

const mealAnalysisSchema = v.object({
  photoKey: v.string({ max: 300 }),
  scaleReadings: v.optional(v.array(v.object({ grams: v.number({ min: 0.1, max: 10_000 }), label: v.optional(v.string({ max: 80 })) }), { max: 12 })),
  hint: v.optional(v.string({ max: 300 })),
  mealCategory: v.optional(v.string({ enum: MEAL_CATEGORIES })),
});

const voiceSchema = v.object({
  transcript: v.string({ min: 1, max: 2000 }),
  mealCategory: v.optional(v.string({ enum: MEAL_CATEGORIES })),
});

const coachSchema = v.object({
  conversationId: v.id(64),
  message: v.string({ min: 1, max: 4000 }),
});

/** Map model failures to the API error envelope (refusal → 422, max_tokens → 502, …). */
function asApiError(err) {
  if (err instanceof ClaudeError) {
    const message = err.kind === "refusal"
      ? "Sorry — the assistant can't help with that request. Try rephrasing, or ask about your logged data."
      : err.message;
    return new ApiError(err.code, message, { status: err.status, details: err.category ? { category: err.category } : undefined });
  }
  return err;
}

/**
 * @param {{
 *   repo: import("../lib/db.js").Repository,
 *   media: import("../lib/s3.js").MediaStore,
 *   usda: import("../services/usda.js").UsdaClient,
 *   claude: any,
 *   logger?: any,
 *   now?: () => number,
 * }} deps
 */
export function createHandler(deps) {
  const logger = deps.logger ?? d.logger;
  const withAi = (fn) => async (req) => {
    await consumeAiQuota(deps.repo, req.sub);
    try {
      return await fn(req);
    } catch (err) {
      throw asApiError(err);
    }
  };

  return createRouter([
    {
      method: "POST", path: "/v1/photos/upload-url",
      handler: async ({ sub, body }) => {
        const input = validate(uploadSchema, body ?? {});
        const photoKey = mealPhotoKey(sub, input.mealId);
        const expiresIn = 300;
        const { url, headers } = await deps.media.presignPut({
          key: photoKey, contentType: input.contentType, contentLength: input.contentLength, expiresIn, tagging: MEAL_RETENTION_TAG,
        });
        return json(200, { uploadUrl: url, photoKey, expiresIn, requiredHeaders: headers, maxBytes: MAX_PHOTO_BYTES });
      },
    },
    {
      method: "POST", path: "/v1/ai/meal-analysis",
      handler: withAi(async ({ sub, body }) => {
        const input = validate(mealAnalysisSchema, body ?? {});
        const analysis = await analyzeMealPhoto({ sub, input, deps: { media: deps.media, claude: deps.claude, usda: deps.usda, repo: deps.repo, now: deps.now } });
        return json(200, analysis);
      }),
    },
    {
      method: "POST", path: "/v1/ai/voice-parse",
      handler: withAi(async ({ body }) => {
        const input = validate(voiceSchema, body ?? {});
        const result = await parseVoiceLog({ input, deps: { claude: deps.claude, usda: deps.usda } });
        return json(200, result);
      }),
    },
    {
      method: "POST", path: "/v1/ai/coach",
      handler: withAi(async ({ sub, body }) => {
        const input = validate(coachSchema, body ?? {});
        const result = await runCoachTurn({ sub, input, deps: { claude: deps.claude, repo: deps.repo, data: createUserData(deps.repo, sub), now: deps.now } });
        return json(200, result);
      }),
    },
  ], { logger });
}

export const handler = d.lazyHandler(createHandler, async () => ({
  repo: await d.repository(),
  media: await d.mediaStore(),
  usda: await d.usdaClient(),
  claude: await d.claudeClient(),
}));
