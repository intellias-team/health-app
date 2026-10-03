# HealthApp backend (AWS SAM)

Serverless backend for the HealthApp iPhone app. Contracts:
[`docs/02-database-schema.md`](../docs/02-database-schema.md) and
[`docs/03-api-architecture.md`](../docs/03-api-architecture.md).

```
Cognito (Sign in with Apple) ─▶ HTTP API (JWT authorizer) ─▶ Lambda (Node.js 22, ESM, arm64)
  DynamoDB (HealthAppData, HealthAppFoodCatalog) · S3 media (SSE-KMS) · KMS (data + token keys)
  Secrets Manager (Oura, USDA) · SQS (Oura webhooks + DLQ) · EventBridge Scheduler · SNS → APNs
  Claude on Amazon Bedrock (Mantle Messages endpoint via @anthropic-ai/bedrock-sdk)
```

## Layout

| Path | What |
|---|---|
| `template.yaml` | Every AWS resource, IAM policy, route and schedule |
| `src/handlers/` | One Lambda per bounded context; each exports `handler` and `createHandler(deps)` |
| `src/lib/` | HTTP/router, key builders, repository (optimistic concurrency, change feed, tombstones), KMS envelope encryption, S3, validation, logger, rate limit |
| `src/services/` | Nutrition math, USDA/OFF clients, source merge, energy + fueling insight, stats, trends, day summary, Oura client/sync, notifications |
| `src/services/ai/` | Bedrock client, meal photo recognition, voice parsing, coach tool loop |
| `test/` | `node:test` unit tests with an in-memory DynamoDB fake, fake fetch, fake Claude |

AWS and Anthropic SDKs are imported lazily inside factory functions, so every pure module and every
handler (with injected fakes) runs without `node_modules`.

## Prerequisites

- Node.js 22, npm
- AWS SAM CLI ≥ 1.120 and credentials for the target account
- Apple Developer account (Sign in with Apple), Oura developer app, USDA FoodData Central API key
- Amazon Bedrock access to the Claude model in your region
- Optional: an SNS platform application for APNs (token-based `.p8` auth)

## Deploy

```bash
npm ci
sam build
sam deploy --guided            # first time; answers are saved to samconfig.toml
```

### Parameters

| Parameter | Default | Notes |
|---|---|---|
| `Stage` | `dev` | `dev` or `prod`. `prod` turns on DynamoDB/Cognito deletion protection |
| `BedrockModelId` | `anthropic.claude-opus-5-5` | Model id on the Bedrock Mantle endpoint |
| `BedrockRegion` | *(stack region)* | Region to call Bedrock in |
| `CognitoDomainPrefix` | `healthapp` | Hosted UI domain is `<prefix>-<stage>.auth.<region>.amazoncognito.com` |
| `AppleServicesId` / `AppleTeamId` / `AppleKeyId` | — | Sign in with Apple configuration |
| `ApplePrivateKey` | — | `NoEcho`; contents of the `.p8` key |
| `ApnsPlatformApplicationArn` | *(empty)* | Leave empty to disable push |
| `AppScheme` | `healthapp` | Used for OAuth redirects back into the app |
| `LogRetentionDays` | `30` | CloudWatch log retention |

After the first deploy, fill in the two secrets (outputs `OuraSecretArn`, `UsdaSecretArn`):

```bash
aws secretsmanager put-secret-value --secret-id healthapp/dev/usda-fdc --secret-string '{"apiKey":"<FDC key>"}'
# keep the generated webhookVerificationToken when updating the Oura secret:
aws secretsmanager get-secret-value --secret-id healthapp/dev/oura --query SecretString --output text
aws secretsmanager put-secret-value --secret-id healthapp/dev/oura \
  --secret-string '{"clientId":"…","clientSecret":"…","webhookVerificationToken":"<generated value>"}'
```

## Sign in with Apple setup

1. **App ID** — in Certificates, Identifiers & Profiles enable *Sign in with Apple* on the app's App ID.
2. **Services ID** — create one (e.g. `com.example.healthapp.signin`); this is `AppleServicesId`.
   Configure *Sign in with Apple* on it with:
   - Domain: `<CognitoDomainPrefix>-<Stage>.auth.<region>.amazoncognito.com`
   - Return URL: `https://<CognitoDomainPrefix>-<Stage>.auth.<region>.amazoncognito.com/oauth2/idpresponse`
     (also printed as the `AppleReturnUrl` output)
3. **Key** — create a key with *Sign in with Apple* enabled, download the `.p8` (→ `ApplePrivateKey`) and
   note its Key ID (→ `AppleKeyId`). Your Team ID is `AppleTeamId`.
4. The app opens the Hosted UI with
   `https://<HostedUiDomain>/oauth2/authorize?identity_provider=SignInWithApple&response_type=code&client_id=<ClientId>&redirect_uri=healthapp://auth/callback&scope=openid+email+profile&code_challenge=…&code_challenge_method=S256`
   via `ASWebAuthenticationSession`, then exchanges the code at `/oauth2/token`. The API authorizer validates the
   **access token** (issuer = user pool, `client_id` = app client).

## Oura app registration

1. Create an application at <https://cloud.ouraring.com/oauth/applications>.
2. Redirect URI: `https://<api>/v1/integrations/oura/callback` (output `OuraRedirectUri`; if you put a custom
   domain in front of the API, set `OURA_REDIRECT_URI` on the Oura function to the public URL).
3. Put the client id/secret into the Oura secret (above).
4. Webhooks: create subscriptions (one per `event_type` × `data_type` you want — `daily_sleep`, `daily_readiness`,
   `daily_activity`, `sleep`, `workout`, `daily_spo2`) with callback `https://<api>/v1/webhooks/oura` and the
   secret's `webhookVerificationToken`. `createWebhookSubscription()` in `src/services/oura.js` does this:

   ```bash
   node -e 'import("./src/services/oura.js").then(async (o) => { for (const d of ["daily_sleep","daily_readiness","daily_activity","sleep","workout","daily_spo2"]) for (const e of ["create","update"]) console.log(await o.createWebhookSubscription({ clientId: process.env.OURA_CLIENT_ID, clientSecret: process.env.OURA_CLIENT_SECRET, callbackUrl: process.env.CALLBACK, verificationToken: process.env.VERIFY, eventType: e, dataType: d })) })'
   ```
5. The app calls `POST /v1/integrations/oura/authorize`, opens the returned URL, and is redirected to
   `healthapp://oura/connected` (or `healthapp://oura/error?reason=…`). A 30-day backfill is queued on connect.
   Oura doesn't document PKCE, so no verifier is stored unless `OURA_USE_PKCE=true`; the server-held client
   secret protects the exchange.

## Bedrock model access

Enable access to the Claude model in the Bedrock console for the region in `BedrockRegion`. The backend uses the
official Anthropic Bedrock SDK Mantle client (`AnthropicBedrockMantle`), which signs requests for the
`bedrock-mantle` service; the template grants `bedrock-mantle:*` plus `bedrock:InvokeModel*`. Narrow the Mantle
action once you've confirmed the exact action name for your region.

Model usage notes (enforced in `src/services/ai/claude.js`): `thinking: {type: "adaptive"}` only, explicit
`output_config.effort`, no assistant prefill, `tool_choice: auto` only, structured outputs via
`output_config.format` (JSON schema), and `stop_reason` is checked before reading content.

**Refusal fallbacks are not configured.** A request that ends with `stop_reason: "refusal"` returns a friendly
`422 AI_REFUSED` (with `details.category` when provided); `max_tokens` returns `502 AI_INCOMPLETE`. If you want
automatic fallback to another model, the SDK's client-side refusal-fallback middleware
(`betaRefusalFallbackMiddleware` + `BetaFallbackState` from `@anthropic-ai/sdk`) is the option on Bedrock — the
server-side `fallbacks` parameter isn't available there.

Prompts contain only the photo, the transcript, or the caller's own health data — never name, email or Apple ID.
Nutrients are always computed from USDA × grams; the model never supplies calories.

## USDA FoodData Central

Get a free key at <https://fdc.nal.usda.gov/api-key-signup> and store it in the USDA secret. Lookups are cached
in `HealthAppFoodCatalog` (foods/barcodes 30 days, searches 1 day). Barcodes fall back to Open Food Facts
(ODbL — show "Data from Open Food Facts" where OFF foods appear).

## Local testing

```bash
npm test                 # node --test, no AWS needed (works even without node_modules)
sam build && sam local invoke HealthFn -e my-event.json --env-vars env.json   # API GW v2 event + env overrides
```

Handlers accept injected dependencies via `createHandler(deps)`; see `test/helpers/fakes.js` for the
in-memory DynamoDB fake, fake fetch, fake Claude client and fake media store.

## Design notes

- **Isolation**: `sub` comes only from `requestContext.authorizer.jwt.claims.sub`; every user key builder takes
  `sub` and prefixes `USER#`, and key segments reject `#`.
- **Sync**: writes use `attribute_not_exists(PK) OR version = :expected`; every syncable write stamps
  `GSI1SK = UPD#<updatedAt>#<entityType>#<id>`; deletes become tombstones with `expiresAt` +90 days.
  `/v1/sync/pull` cursors are the last `GSI1SK` (base64url-encoded).
- **Oura**: tokens are envelope-encrypted (KMS data key + AES-256-GCM, encryption context `{sub, purpose}`);
  refresh tokens rotate and are persisted immediately; an app-wide `SYSTEM#oura / RATE#<5-min window>` counter
  protects the shared client quota; webhook HMAC + 5-minute skew are verified before enqueueing.
- **Photos**: presigned PUT (5 min, `image/jpeg`, tagged `retention=meal-30d`). A presigned PUT can't enforce size,
  so `aiFn` checks `ContentLength ≤ 8 MB` and the JPEG magic bytes before calling the model.
- **Trends** never mix sources for HRV (SDNN vs RMSSD) or resting HR (Apple resting vs Oura sleep-lowest).
- **Fueling language** is neutral: low intake vs expenditure produces a recovery-and-fueling note, never praise.

## Cost notes (rough, us-east-1, small user base)

- Lambda/API Gateway/DynamoDB on-demand/SQS: pennies per active user per month.
- KMS: $1/month per CMK (2 keys) + $0.03 per 10k requests; S3 Bucket Keys keep media KMS calls low.
- Secrets Manager: $0.40/secret/month (2 secrets). Cognito: Essentials tier pricing per MAU.
- Bedrock is the dominant variable cost: each photo analysis is one vision call; coach turns can be up to 6 calls.
  The per-user AI limit (30/hour) caps worst-case spend; use lower `effort` to reduce cost further.
- The 15-minute notification job reads ~30 days of metrics per user with a device; at scale, shard by timezone.

## Known limitations / deviations

- WAF: AWS WAF cannot be attached to API Gateway **HTTP** APIs; put CloudFront (with WAF) in front of the API
  for prod if WAF is required.
- S3 lifecycle uses object tags (prefix filters can't wildcard the `<sub>` segment).
- GSI2 additionally holds push-device items (`PUSHDEVICE#<sub>`) so the notification job can enumerate devices
  without scanning the base table.
- Table/bucket names include the stage (and the bucket the account id) so several stages can share an account.
