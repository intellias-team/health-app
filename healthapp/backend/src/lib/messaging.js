/**
 * SNS (APNs mobile push) and SQS adapters. SDKs are imported lazily.
 */

/**
 * @typedef {Object} PushAdapter
 * @property {(p: { token: string, userData?: string }) => Promise<string>} createEndpoint  returns EndpointArn
 * @property {(endpointArn: string, token: string) => Promise<void>} refreshEndpoint
 * @property {(endpointArn: string, message: string) => Promise<void>} publish
 * @property {(endpointArn: string) => Promise<void>} deleteEndpoint
 */

/** Thrown when SNS reports the endpoint as disabled (APNs token no longer valid). */
export class EndpointDisabledError extends Error {
  constructor() {
    super("Push endpoint disabled");
    this.name = "EndpointDisabledError";
  }
}

/**
 * @param {{ platformApplicationArn?: string }} opts
 * @returns {Promise<PushAdapter|null>} null when push is not configured
 */
export async function createPushAdapter({ platformApplicationArn }) {
  if (!platformApplicationArn) return null;
  const sns = await import("@aws-sdk/client-sns");
  const client = new sns.SNSClient({});
  return {
    async createEndpoint({ token, userData }) {
      const res = await client.send(new sns.CreatePlatformEndpointCommand({ PlatformApplicationArn: platformApplicationArn, Token: token, CustomUserData: userData }));
      return res.EndpointArn;
    },
    async refreshEndpoint(endpointArn, token) {
      await client.send(new sns.SetEndpointAttributesCommand({ EndpointArn: endpointArn, Attributes: { Token: token, Enabled: "true" } }));
    },
    async publish(endpointArn, message) {
      try {
        await client.send(new sns.PublishCommand({ TargetArn: endpointArn, MessageStructure: "json", Message: message }));
      } catch (err) {
        if (err?.name === "EndpointDisabledException" || err?.name === "EndpointDisabled") throw new EndpointDisabledError();
        throw err;
      }
    },
    async deleteEndpoint(endpointArn) {
      await client.send(new sns.DeleteEndpointCommand({ EndpointArn: endpointArn }));
    },
  };
}

/**
 * @param {{ queueUrl: string }} opts
 * @returns {Promise<{ send: (body: unknown) => Promise<void> }>}
 */
export async function createQueue({ queueUrl }) {
  const sqs = await import("@aws-sdk/client-sqs");
  const client = new sqs.SQSClient({});
  return {
    async send(body) {
      await client.send(new sqs.SendMessageCommand({ QueueUrl: queueUrl, MessageBody: JSON.stringify(body) }));
    },
  };
}
