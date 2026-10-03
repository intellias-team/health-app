/**
 * Claude on Amazon Bedrock via the official Anthropic Bedrock SDK (Mantle client).
 *
 * Model facts for `anthropic.claude-opus-5-5` honoured here:
 *  - `thinking: { type: "adaptive" }` only (no `budget_tokens`, no `{type:"disabled"}` — both 400)
 *  - `output_config.effort` is set explicitly on every call (model default is "medium")
 *  - no assistant prefill; `tool_choice` is `auto` only (forced `any`/`tool` → 400)
 *  - structured JSON via `output_config.format = { type: "json_schema", schema }`
 *  - `stop_reason` is checked before content is read; `refusal` and `max_tokens` become typed errors
 *
 * Refusal fallbacks are NOT configured: a `refusal` surfaces as ClaudeError("refusal") → HTTP 422.
 * (On Bedrock the server-side `fallbacks` parameter is unavailable; the SDK's client-side
 * `betaRefusalFallbackMiddleware` is the option if fallback routing is wanted later.)
 */

export const DEFAULT_MODEL_ID = "anthropic.claude-opus-5-5";
export const DEFAULT_MAX_TOKENS = 16_000;

/** @returns {string} */
export const modelId = () => process.env.BEDROCK_MODEL_ID || DEFAULT_MODEL_ID;

/**
 * Typed error for Claude failures. `status`/`code` map straight to the API error envelope.
 */
export class ClaudeError extends Error {
  /**
   * @param {"refusal"|"max_tokens"|"rate_limited"|"upstream"|"bad_response"} kind
   * @param {string} message
   * @param {{ category?: string|null, cause?: unknown }} [extra]
   */
  constructor(kind, message, extra = {}) {
    super(message, { cause: extra.cause });
    this.name = "ClaudeError";
    this.kind = kind;
    this.category = extra.category ?? null;
    const map = {
      refusal: [422, "AI_REFUSED"],
      max_tokens: [502, "AI_INCOMPLETE"],
      rate_limited: [429, "RATE_LIMITED"],
      upstream: [502, "UPSTREAM_ERROR"],
      bad_response: [502, "UPSTREAM_ERROR"],
    };
    [this.status, this.code] = map[kind];
  }
}

/**
 * Create the Bedrock Mantle client. The SDK is imported lazily so tests never need it.
 * @param {{ awsRegion?: string }} [opts]
 * @returns {Promise<any>} AnthropicBedrockMantle instance
 */
export async function createClaudeClient(opts = {}) {
  const { AnthropicBedrockMantle } = await import("@anthropic-ai/bedrock-sdk");
  return new AnthropicBedrockMantle({
    awsRegion: opts.awsRegion ?? process.env.BEDROCK_REGION ?? process.env.AWS_REGION,
    maxRetries: 2,
    timeout: 120_000,
  });
}

/**
 * Map SDK errors to ClaudeError using the SDK's typed error classes, which the client class
 * exposes as statics (e.g. `AnthropicBedrockMantle.RateLimitError`). Most specific first.
 * @param {unknown} err @param {any} client
 */
export function mapSdkError(err, client) {
  if (err instanceof ClaudeError) return err;
  const SDK = client?.constructor ?? {};
  const is = (name) => typeof SDK[name] === "function" && err instanceof SDK[name];
  if (is("RateLimitError")) return new ClaudeError("rate_limited", "Model is busy, try again shortly", { cause: err });
  if (is("BadRequestError")) return new ClaudeError("upstream", "Model rejected the request", { cause: err });
  if (is("AuthenticationError") || is("PermissionDeniedError")) return new ClaudeError("upstream", "Model access is not configured", { cause: err });
  if (is("APIConnectionError")) return new ClaudeError("upstream", "Could not reach the model", { cause: err });
  if (is("InternalServerError") || is("APIError")) return new ClaudeError("upstream", "Model service error", { cause: err });
  return new ClaudeError("upstream", "Model call failed", { cause: err });
}

/**
 * Call `messages.create` and validate `stop_reason` before anything reads content.
 * `tool_use` and `end_turn` are returned to the caller; `refusal`/`max_tokens` throw.
 * @param {any} client
 * @param {Record<string, any>} params
 */
export async function createMessage(client, params) {
  let response;
  try {
    response = await client.messages.create({
      model: modelId(),
      max_tokens: DEFAULT_MAX_TOKENS,
      thinking: { type: "adaptive" },
      ...params,
      output_config: { effort: "medium", ...(params.output_config ?? {}) },
    });
  } catch (err) {
    throw mapSdkError(err, client);
  }
  switch (response?.stop_reason) {
    case "refusal":
      throw new ClaudeError("refusal", "The assistant declined this request", { category: response.stop_details?.category ?? null });
    case "max_tokens":
      throw new ClaudeError("max_tokens", "The model response was cut off");
    case "end_turn":
    case "tool_use":
    case "stop_sequence":
      return response;
    default:
      throw new ClaudeError("bad_response", `Unexpected stop_reason '${response?.stop_reason}'`);
  }
}

/** Concatenate text blocks (narrowing the content union on `type === "text"`). */
export function extractText(response) {
  return (response?.content ?? [])
    .filter((block) => block.type === "text")
    .map((block) => block.text)
    .join("");
}

/**
 * Structured-output call: returns the parsed JSON object matching `schema`.
 * @param {any} client
 * @param {{ system: string, content: any[], schema: object, effort?: "low"|"medium"|"high", maxTokens?: number }} p
 */
export async function structuredCall(client, { system, content, schema, effort = "medium", maxTokens = DEFAULT_MAX_TOKENS }) {
  const response = await createMessage(client, {
    max_tokens: maxTokens,
    system,
    messages: [{ role: "user", content }],
    output_config: { effort, format: { type: "json_schema", schema } },
  });
  const text = extractText(response);
  try {
    return JSON.parse(text);
  } catch (err) {
    throw new ClaudeError("bad_response", "Model returned invalid JSON", { cause: err });
  }
}
