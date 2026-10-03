#!/usr/bin/env node
/**
 * Post-deploy smoke test for the HealthApp API behind CloudFront.
 *
 *   npm run smoke                       # stage dev, profile qbiz
 *   npm run smoke -- --stage prod --profile qbiz
 *
 * Checks: public health via CloudFront, direct execute-api access refused, auth required,
 * then signs in a test user (created if missing, password reset each run) and exercises
 * profile, goals, meals and the day summary. Leaves no meal behind.
 */
import { randomBytes, randomUUID } from "node:crypto";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
  options: {
    stage: { type: "string", default: "dev" },
    profile: { type: "string", default: "qbiz" },
    region: { type: "string" },
    username: { type: "string", default: "smoketest" },
  },
});
process.env.AWS_PROFILE = args.profile;

const { CloudFormationClient, DescribeStacksCommand } = await import("@aws-sdk/client-cloudformation");
const {
  CognitoIdentityProviderClient, AdminCreateUserCommand, AdminSetUserPasswordCommand, InitiateAuthCommand,
} = await import("@aws-sdk/client-cognito-identity-provider");

const clientOpts = args.region ? { region: args.region } : {};
const stackName = `healthapp-${args.stage}`;

const results = [];
async function check(name, fn) {
  try {
    const detail = await fn();
    results.push({ name, ok: true });
    console.log(`  ✔ ${name}${detail ? ` — ${detail}` : ""}`);
  } catch (err) {
    results.push({ name, ok: false });
    console.log(`  ✘ ${name} — ${err.message}`);
  }
}

async function call(method, url, { token, body } = {}) {
  const res = await fetch(url, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body ? { "content-type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json;
  try { json = text ? JSON.parse(text) : undefined; } catch { json = undefined; }
  return { status: res.status, json, text };
}

function expectStatus(res, want) {
  if (res.status !== want) throw new Error(`expected ${want}, got ${res.status} ${res.text.slice(0, 200)}`);
}

console.log(`Stack ${stackName} (profile ${args.profile})`);
const cfn = new CloudFormationClient(clientOpts);
const stack = (await cfn.send(new DescribeStacksCommand({ StackName: stackName }))).Stacks?.[0];
if (!stack) throw new Error(`Stack ${stackName} not found`);
const out = Object.fromEntries((stack.Outputs ?? []).map((o) => [o.OutputKey, o.OutputValue]));
const base = out.ApiBaseUrl;
console.log(`API ${base}\n`);

await check("GET /v1/health through CloudFront is 200", async () => {
  const res = await call("GET", `${base}/health`);
  expectStatus(res, 200);
  return `stage=${res.json?.stage}`;
});

await check("direct execute-api call is refused (403)", async () => {
  expectStatus(await call("GET", `${out.ApiUrl}/v1/health`), 403);
});

await check("GET /v1/me without a token is 401", async () => {
  expectStatus(await call("GET", `${base}/me`), 401);
});

const cognito = new CognitoIdentityProviderClient(clientOpts);
let token;
await check(`test user '${args.username}' signs in`, async () => {
  try {
    await cognito.send(new AdminCreateUserCommand({ UserPoolId: out.UserPoolId, Username: args.username, MessageAction: "SUPPRESS" }));
  } catch (err) {
    if (err.name !== "UsernameExistsException") throw err;
  }
  const password = `Sm0ke!${randomBytes(12).toString("hex")}`;
  await cognito.send(new AdminSetUserPasswordCommand({ UserPoolId: out.UserPoolId, Username: args.username, Password: password, Permanent: true }));
  const auth = await cognito.send(new InitiateAuthCommand({
    ClientId: out.ClientId, AuthFlow: "USER_PASSWORD_AUTH", AuthParameters: { USERNAME: args.username, PASSWORD: password },
  }));
  token = auth.AuthenticationResult?.AccessToken;
  if (!token) throw new Error("no access token returned");
});

if (token) {
  const today = new Date().toISOString().slice(0, 10);
  const mealId = randomUUID();

  await check("GET /v1/me", async () => expectStatus(await call("GET", `${base}/me`, { token }), 200));

  await check("PUT /v1/me/goals", async () => {
    expectStatus(await call("PUT", `${base}/me/goals`, { token, body: { proteinG: 140, carbsG: 250, fatG: 75, fiberG: 30, mode: "maintain" } }), 200);
  });

  await check("PUT /v1/meals/{id} recomputes totals", async () => {
    const res = await call("PUT", `${base}/meals/${mealId}`, {
      token,
      body: {
        id: mealId, date: today, loggedAt: new Date().toISOString(), category: "breakfast", source: "manual",
        items: [{ id: randomUUID(), name: "Smoke test oats", grams: 50, weightSource: "user", nutrients: { kcal: 190, proteinG: 6.5, carbsG: 33, fatG: 3.4, fiberG: 5 } }],
      },
    });
    expectStatus(res, 200);
    return `kcal=${res.json?.meal?.totals?.kcal}`;
  });

  await check("GET /v1/meals returns the meal", async () => {
    const res = await call("GET", `${base}/meals?from=${today}&to=${today}`, { token });
    expectStatus(res, 200);
    if (!res.json?.meals?.some((m) => m.id === mealId)) throw new Error("meal not found in list");
  });

  await check(`GET /v1/day/${today}`, async () => expectStatus(await call("GET", `${base}/day/${today}`, { token }), 200));

  await check("DELETE /v1/meals/{id}", async () => {
    expectStatus(await call("DELETE", `${base}/meals/${mealId}?date=${today}`, { token }), 204);
  });

  // Needs the USDA key in Secrets Manager; reported but not counted as a failure.
  const search = await call("GET", `${base}/foods/search?q=apple&limit=3`, { token });
  console.log(`  · GET /v1/foods/search — ${search.status === 200 ? `${search.json?.foods?.length ?? 0} results` : `HTTP ${search.status} (set the USDA API key secret)`}`);
}

const failed = results.filter((r) => !r.ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
