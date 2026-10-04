# HealthApp — notes for Claude Code

Health + nutrition tracker: AWS serverless backend now, SwiftUI iOS app later.
This copy is worked on locally (no GitHub). Commit to local git only; do not add remotes or push unless asked.

## Layout
- `healthapp/docs/` — design docs 01–11. `02-database-schema.md` and `03-api-architecture.md` are the API/data contracts.
- `healthapp/backend/` — AWS SAM app: Cognito, CloudFront → API Gateway HTTP API → Lambda (Node.js 22, esbuild bundles), DynamoDB, S3, KMS, Secrets Manager, SQS, EventBridge, Bedrock (Claude).
- `healthapp/ios/` — SwiftUI app + HealthAppKit package (not built yet; needs a Mac + Xcode 16).

## Backend commands (run in `healthapp/backend`)
- `npm ci` then `npm test` — 68 node:test unit tests, no AWS needed.
- `npm run deploy` — `sam build && sam deploy` to stack `healthapp-dev` with AWS profile `qbiz` (see `samconfig.toml`). Shows a change set; confirm with `y`.
- `npm run smoke` — post-deploy checks through CloudFront (creates/uses Cognito test user `smoketest`).
- `npm run deploy:prod` / `npm run smoke:prod` — prod stack `healthapp-prod`.
- `npm run logs` — tail Lambda logs.

## Status
- Backend has never been deployed yet. First deploy: ~5–15 min (CloudFront).
- Region = the `qbiz` profile's default region.
- After deploy, still to configure: Bedrock model access for `anthropic.claude-opus-5-5`; USDA API key in secret `healthapp/dev/usda-fdc`; Oura app + secret `healthapp/dev/oura`; Sign in with Apple (optional, test users work meanwhile).
- Public API base URL = stack output `ApiBaseUrl` (`https://<id>.cloudfront.net/v1`). Direct execute-api calls get 403 by design.

## Conventions
- Never put secrets in code or chat; they live in Secrets Manager.
- Keep `npm test` green and the template lint-clean before deploying.
