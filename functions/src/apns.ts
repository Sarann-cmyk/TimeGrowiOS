import * as http2 from "http2";
import jwt from "jsonwebtoken";

const APNS_HOST_SANDBOX = "api.sandbox.push.apple.com";
const APNS_HOST_PRODUCTION = "api.push.apple.com";

export interface ApnsCredentials {
  /** Contents of the .p8 APNs Auth Key file. */
  authKey: string;
  keyId: string;
  teamId: string;
  bundleId: string;
  /** Matches the app's `aps-environment` entitlement. */
  useSandbox: boolean;
}

interface CachedToken {
  value: string;
  issuedAt: number;
}

// Apple asks providers not to generate a fresh token more than once per ~20 minutes; cache well
// under the 1-hour hard expiry.
const TOKEN_TTL_SECONDS = 50 * 60;
let cachedToken: CachedToken | null = null;

function providerToken(creds: ApnsCredentials): string {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < TOKEN_TTL_SECONDS) {
    return cachedToken.value;
  }
  const value = jwt.sign({ iss: creds.teamId, iat: now }, creds.authKey, {
    algorithm: "ES256",
    header: { alg: "ES256", kid: creds.keyId },
  });
  cachedToken = { value, issuedAt: now };
  return value;
}

let sessionsByHost = new Map<string, http2.ClientHttp2Session>();

function session(host: string): http2.ClientHttp2Session {
  const existing = sessionsByHost.get(host);
  if (existing && !existing.closed && !existing.destroyed) {
    return existing;
  }
  const created = http2.connect(`https://${host}`);
  created.on("error", (error) => {
    console.error(`APNs session error (${host})`, error);
    sessionsByHost.delete(host);
  });
  sessionsByHost.set(host, created);
  return created;
}

interface LiveActivityPayload {
  event: "start" | "end";
  contentState: Record<string, unknown>;
  attributesType?: string;
  attributes?: Record<string, unknown>;
  dismissalDate?: number;
}

function sendRaw(
  creds: ApnsCredentials,
  deviceToken: string,
  body: string,
  headers: { topic: string; pushType: string; priority: "5" | "10" }
): Promise<void> {
  return new Promise((resolve, reject) => {
    const host = creds.useSandbox ? APNS_HOST_SANDBOX : APNS_HOST_PRODUCTION;
    const client = session(host);

    const req = client.request({
      ":method": "POST",
      ":path": `/3/device/${deviceToken}`,
      authorization: `bearer ${providerToken(creds)}`,
      "apns-topic": headers.topic,
      "apns-push-type": headers.pushType,
      "apns-priority": headers.priority,
      "content-type": "application/json",
    });

    let status = 0;
    let responseBody = "";
    req.on("response", (responseHeaders) => {
      status = Number(responseHeaders[":status"] ?? 0);
    });
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      responseBody += chunk;
    });
    req.on("end", () => {
      if (status >= 200 && status < 300) {
        resolve();
      } else {
        reject(new Error(`APNs responded ${status}: ${responseBody}`));
      }
    });
    req.on("error", reject);
    req.end(body);
  });
}

function send(creds: ApnsCredentials, deviceToken: string, payload: LiveActivityPayload): Promise<void> {
  const aps: Record<string, unknown> = {
    timestamp: Math.floor(Date.now() / 1000),
    event: payload.event,
    "content-state": payload.contentState,
  };
  if (payload.attributesType) aps["attributes-type"] = payload.attributesType;
  if (payload.attributes) aps["attributes"] = payload.attributes;
  if (payload.dismissalDate) aps["dismissal-date"] = payload.dismissalDate;

  return sendRaw(creds, deviceToken, JSON.stringify({ aps }), {
    topic: `${creds.bundleId}.push-type.liveactivity`,
    pushType: "liveactivity",
    priority: "10",
  });
}

/** Starts a brand-new Live Activity on a device via its push-to-start token. */
export function sendLiveActivityStart(
  creds: ApnsCredentials,
  pushToStartToken: string,
  attributesType: string,
  attributes: Record<string, unknown>,
  contentState: Record<string, unknown>
): Promise<void> {
  return send(creds, pushToStartToken, { event: "start", contentState, attributesType, attributes });
}

/** Ends an already-running Live Activity. */
export function sendLiveActivityEnd(
  creds: ApnsCredentials,
  activityPushToken: string,
  contentState: Record<string, unknown>
): Promise<void> {
  return send(creds, activityPushToken, {
    event: "end",
    contentState,
    dismissalDate: Math.floor(Date.now() / 1000),
  });
}

/**
 * Silently wakes the app in the background (`content-available: 1`), so it can run
 * `LiveActivityManager.reconcile()` itself instead of relying on the less reliable
 * ActivityKit push-to-start channel. Uses the app's bare bundle ID as topic and
 * `apns-push-type: background` — a different channel from the Live Activity push above.
 */
export function sendBackgroundWake(creds: ApnsCredentials, apnsDeviceToken: string): Promise<void> {
  const body = JSON.stringify({ aps: { "content-available": 1 } });
  return sendRaw(creds, apnsDeviceToken, body, {
    topic: creds.bundleId,
    pushType: "background",
    priority: "5",
  });
}
