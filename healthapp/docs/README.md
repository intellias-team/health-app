# HealthApp documentation

Design documentation for HealthApp — a premium iPhone app that puts fueling, training and recovery on one screen, with data from Apple Health, Oura, smart scales, Bluetooth food scales and AI food logging.

**Binding contracts:** docs 02 and 03. Every other document follows them; if they conflict, 02/03 win and the other doc gets fixed.

| # | Document | What it covers |
|---|---|---|
| 01 | [Product architecture](01-product-architecture.md) | Vision and principles, personas, feature map by tab, system/module/deployment diagrams, data flows, source precedence, NFRs, privacy/compliance, Daily Energy copy rules, AI safety rules |
| 02 | [Database schema](02-database-schema.md) | **Contract.** DynamoDB tables, key patterns, meal and daily-metrics shapes, S3 layout, on-device store |
| 03 | [API architecture](03-api-architecture.md) | **Contract.** HTTP API topology, Lambda functions, endpoints, offline sync algorithm, security controls |
| 04 | [HealthKit data model](04-healthkit-data-model.md) | Types read and written, units, aggregation, mapping to our schema, sleep handling, dedupe, background delivery, authorization UX, day boundaries, Swift protocol |
| 05 | [Oura integration plan](05-oura-integration-plan.md) | Server-side OAuth 2.0, scopes, endpoints, field mapping, webhooks, hourly reconciliation, token lifecycle, rate limits, error states, test plan |
| 06 | [Food scale & body scale architecture](06-food-scale-ble-architecture.md) | `FoodScaleDriver` plugin system, CoreBluetooth state machine, WSS/BCS parsing, stable-weight detection, tare, multi-item weighing, adding a new scale, body-scale providers |
| 07 | [AI meal recognition pipeline](07-ai-meal-recognition-pipeline.md) | Photo → Claude on Bedrock → USDA matching → ranges → confirm UI; prompt and JSON schema, scale fusion, voice, barcode, honesty rules, evaluation, cost, safety, privacy |
| 08 | [Wireframes](08-wireframes.md) | Low-fi wireframes and states for each screen, plus the visual design system |
| 09 | [SwiftUI project structure](09-swiftui-project-structure.md) | iOS module tree, dependency graph, DI and demo/live setup, concurrency, persistence, background tasks, testing, how to add an integration |
| 10 | [MVP plan & roadmap](10-mvp-plan-and-roadmap.md) | MVP scope and acceptance criteria, current repo state, milestones M0–M5, risks, success metrics, open questions |
| 11 | [AWS infrastructure & security](11-aws-infrastructure-and-security.md) | Resources, IAM matrix, STRIDE threat model, environments, CI/CD, observability, backup/DR, cost estimates |

Conventions: Mermaid diagrams render on GitHub. Third-party facts that may have changed (Oura scopes and limits, Bedrock pricing, HealthKit availability by iOS version) are marked *verify against current docs*.
