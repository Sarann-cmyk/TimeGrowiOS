import { onDocumentUpdated, onDocumentWritten } from "firebase-functions/v2/firestore";
import { onRequest } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import type { Timestamp } from "firebase-admin/firestore";
import { createHash, timingSafeEqual } from "crypto";
import {
  sendBackgroundWake,
  sendLiveActivityEnd,
  sendLiveActivityStart,
  sendLiveActivityUpdate,
  type ApnsCredentials,
} from "./apns";

admin.initializeApp();
const db = admin.firestore();

const APNS_AUTH_KEY = defineSecret("APNS_AUTH_KEY");
const APNS_KEY_ID = defineSecret("APNS_KEY_ID");
const APNS_TEAM_ID = defineSecret("APNS_TEAM_ID");

const BUNDLE_ID = "WINNER.ltd.TimeGrow";
const ATTRIBUTES_TYPE = "TimeGrowLiveActivityAttributes";

function credentials(): ApnsCredentials {
  return {
    authKey: APNS_AUTH_KEY.value(),
    keyId: APNS_KEY_ID.value(),
    teamId: APNS_TEAM_ID.value(),
    bundleId: BUNDLE_ID,
    // Matches TimeGrow.entitlements' `aps-environment = development`. Flip to false once the app
    // ships with a production/TestFlight provisioning profile (aps-environment = production).
    useSandbox: true,
  };
}

interface TaskDoc {
  name?: string;
  colorHex?: string;
  timerStartedAt?: Timestamp;
  autoTrackSessionStartedAt?: Timestamp;
  autoTrackLiveUntil?: Timestamp;
  autoTrackStoppedAt?: Timestamp;
  liveActivityPushToken?: string;
}

interface DeviceDoc {
  activityPushToStartToken?: string;
  /** SHA-256 only; the raw per-device secret never reaches Firestore. */
  autoTrackingSecretHash?: string;
}

/** Mirrors `LiveActivityManager.activeTimerStart(for:)` on the iOS side. */
function activeTimerStart(task: TaskDoc, now: Date): Date | null {
  if (task.timerStartedAt) {
    return task.timerStartedAt.toDate();
  }
  if (task.autoTrackSessionStartedAt && task.autoTrackLiveUntil) {
    const startedAt = task.autoTrackSessionStartedAt.toDate();
    const liveUntil = task.autoTrackLiveUntil.toDate();
    const stoppedAt = task.autoTrackStoppedAt?.toDate();
    const wasStoppedAfterStart = stoppedAt ? stoppedAt >= startedAt : false;
    if (liveUntil > now && !wasStoppedAfterStart) {
      return startedAt;
    }
  }
  return null;
}

/**
 * ActivityKit decodes `Date` with Swift's default `.deferredToDate` strategy: a JSON number of
 * seconds since Apple's reference date (2001-01-01), not a Unix timestamp and not an ISO8601
 * string. A Unix timestamp decodes decades into the future and makes `Text(timerInterval:)`
 * display `0:00`.
 */
function contentState(startedAt: Date, now: Date = new Date()): Record<string, number> {
  const appleReferenceDateUnixSeconds = 978_307_200;
  const minuteWindowStart = new Date(Math.floor(now.getTime() / 60_000) * 60_000);
  return {
    startedAt: startedAt.getTime() / 1000 - appleReferenceDateUnixSeconds,
    minuteWindowStart: minuteWindowStart.getTime() / 1000 - appleReferenceDateUnixSeconds,
  };
}

const AUTO_TRACK_LIVE_GRACE_MS = 180_000;
const MAX_CLIENT_EVENT_AGE_MS = 24 * 60 * 60 * 1_000;
const MAX_CLIENT_FUTURE_SKEW_MS = 60_000;

function requestDate(value: unknown, fallback: Date): Date {
  const seconds = typeof value === "number" ? value : Number.NaN;
  const candidate = new Date(seconds * 1_000);
  if (!Number.isFinite(seconds)
      || candidate.getTime() < fallback.getTime() - MAX_CLIENT_EVENT_AGE_MS
      || candidate.getTime() > fallback.getTime() + MAX_CLIENT_FUTURE_SKEW_MS) {
    return fallback;
  }
  return candidate;
}

function secretHash(secret: string): string {
  return createHash("sha256").update(secret, "utf8").digest("hex");
}

function secureHashEquals(expected: string, receivedSecret: string): boolean {
  const expectedBuffer = Buffer.from(expected, "utf8");
  const receivedBuffer = Buffer.from(secretHash(receivedSecret), "utf8");
  return expectedBuffer.length === receivedBuffer.length && timingSafeEqual(expectedBuffer, receivedBuffer);
}

/**
 * Receives Screen Time threshold events even when TimeGrow itself has been inactive for hours.
 * Firebase ID tokens expire in about one hour and cannot be refreshed reliably by a
 * DeviceActivityMonitor extension, so this endpoint instead authenticates a randomly generated,
 * per-device secret. The iOS app stores the raw secret in its App Group; Firestore holds only its
 * SHA-256 hash. A successful transaction creates/extends the auto-track live window, after which
 * `onTaskTimerChanged` immediately dispatches ActivityKit push-to-start to the user's devices.
 */
export const recordAutoTrackEvent = onRequest(async (request, response) => {
  if (request.method !== "POST") {
    response.status(405).json({ error: "method-not-allowed" });
    return;
  }

  const body = request.body as Record<string, unknown> | undefined;
  const uid = typeof body?.uid === "string" ? body.uid : "";
  const deviceID = typeof body?.deviceID === "string" ? body.deviceID : "";
  const deviceSecret = typeof body?.deviceSecret === "string" ? body.deviceSecret : "";
  const taskID = typeof body?.taskID === "string" ? body.taskID : "";
  if (!uid || !deviceID || !deviceSecret || !taskID) {
    response.status(400).json({ error: "invalid-request" });
    return;
  }

  const now = new Date();
  const occurredAt = requestDate(body?.occurredAt, now);
  const requestedSessionStart = requestDate(body?.sessionStartedAt, occurredAt);
  const deviceRef = db.collection("users").doc(uid).collection("devices").doc(deviceID);
  const taskRef = db.collection("users").doc(uid).collection("tasks").doc(taskID);

  try {
    const result = await db.runTransaction(async (transaction) => {
      const deviceSnapshot = await transaction.get(deviceRef);
      const expectedHash = deviceSnapshot.get("autoTrackingSecretHash");
      if (typeof expectedHash !== "string" || !secureHashEquals(expectedHash, deviceSecret)) {
        throw new Error("unauthorized-device");
      }

      const taskSnapshot = await transaction.get(taskRef);
      if (!taskSnapshot.exists) {
        throw new Error("task-not-found");
      }
      const task = taskSnapshot.data() as TaskDoc;
      const wasRunning = activeTimerStart(task, now) !== null;
      const previousAutoStart = task.autoTrackSessionStartedAt?.toDate();
      const previousLiveUntil = task.autoTrackLiveUntil?.toDate();
      const previousStoppedAt = task.autoTrackStoppedAt?.toDate();
      const canContinuePreviousSession = !!previousAutoStart
        && !!previousLiveUntil
        && previousLiveUntil > now
        && (!previousStoppedAt || previousStoppedAt < previousAutoStart);
      const sessionStartedAt = canContinuePreviousSession ? previousAutoStart : requestedSessionStart;
      const liveUntil = new Date(Math.max(now.getTime(), occurredAt.getTime()) + AUTO_TRACK_LIVE_GRACE_MS);

      transaction.update(taskRef, {
        autoTrackLastUsageAt: admin.firestore.Timestamp.fromDate(occurredAt),
        autoTrackLiveUntil: admin.firestore.Timestamp.fromDate(liveUntil),
        autoTrackSessionStartedAt: admin.firestore.Timestamp.fromDate(sessionStartedAt),
        autoTrackStoppedAt: admin.firestore.FieldValue.delete(),
        updatedAt: admin.firestore.Timestamp.fromDate(now),
      });
      return { started: !wasRunning, sessionStartedAt };
    });

    console.log(`secure auto-track event accepted (task ${taskID}, device ${deviceID}, started=${result.started})`);
    response.status(200).json({ ok: true, started: result.started });
  } catch (error) {
    const message = String(error instanceof Error ? error.message : error);
    const status = message === "unauthorized-device" ? 401 : message === "task-not-found" ? 404 : 500;
    if (status === 500) console.error("secure auto-track event failed", error);
    response.status(status).json({ error: status === 500 ? "internal-error" : message });
  }
});

/**
 * Reacts to every task write: starts a Live Activity via push-to-start on every device that has
 * registered a token when a task transitions to running, and ends it via the per-activity push
 * token when a task stops. Covers cross-device start/stop (e.g. auto-tracking on another device)
 * without requiring the app to be foregrounded anywhere.
 */
export const onTaskTimerChanged = onDocumentUpdated(
  { document: "users/{uid}/tasks/{taskID}", secrets: [APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID] },
  async (event) => {
    const before = event.data?.before.data() as TaskDoc | undefined;
    const after = event.data?.after.data() as TaskDoc | undefined;
    if (!before || !after) return;

    const { uid, taskID } = event.params;
    const now = new Date();
    const wasRunning = activeTimerStart(before, now) !== null;
    const runningStart = activeTimerStart(after, now);

    if (!wasRunning && runningStart) {
      const devicesSnap = await db.collection("users").doc(uid).collection("devices").get();
      const creds = credentials();

      // Primary (and, as of 2026-07-14, only viable) path for starting a *new* Live Activity
      // while the app isn't in the foreground: `Activity.request()` on the device throws
      // "Target is not foreground" whenever it's called outside the foreground — confirmed via
      // on-device diagnostics, this is a hard ActivityKit rule, not a reliability quirk. A
      // silent background-wake push can run app code in the background just fine, but that code
      // still can't call `Activity.request()` there, so background-wake alone can never start
      // one — push-to-start is the one Apple-sanctioned exception, since the *system* creates
      // the activity directly, without running app code at all.
      const startTokensByDoc = devicesSnap.docs
        .map((doc) => ({ doc, token: doc.get("activityPushToStartToken") as string | undefined }))
        .filter((entry): entry is { doc: typeof entry.doc; token: string } => !!entry.token);
      if (startTokensByDoc.length > 0) {
        const state = contentState(runningStart);
        const attributes = {
          taskID,
          taskName: after.name ?? "",
          colorHex: after.colorHex ?? "#8CD616",
        };
        await Promise.all(
          startTokensByDoc.map(({ doc, token }) =>
            sendLiveActivityStart(creds, token, ATTRIBUTES_TYPE, attributes, state)
              .then(() => console.log(`push-to-start sent OK (task ${taskID}, device token ${token})`))
              .catch(async (error) => {
                console.error(`push-to-start failed (task ${taskID}, device token ${token})`, error);
                // Apple returns 410 "Unregistered" for a token that no longer resolves to any
                // installed app instance (e.g. a stale token left over from a previous install).
                // Clearing it here keeps future writes from repeatedly retrying dead tokens.
                if (String(error?.message ?? error).includes("410")) {
                  await doc.ref.update({ activityPushToStartToken: admin.firestore.FieldValue.delete() });
                }
              })
          )
        );
      }

      // Secondary: silently wake the app so it can run `LiveActivityManager.reconcile()` for
      // everything push-to-start *doesn't* need foreground for — syncing the per-activity push
      // token, ending activities for tasks that stopped, etc. Also gives the app a chance to
      // pick up state if it happens to already be foreground when this arrives.
      const wakeTokens = devicesSnap.docs
        .map((doc) => doc.get("apnsDeviceToken") as string | undefined)
        .filter((token): token is string => !!token);
      await Promise.all(
        wakeTokens.map((token) =>
          sendBackgroundWake(creds, token)
            .then(() => console.log(`background wake sent OK (task ${taskID}, device token ${token})`))
            .catch((error) => console.error(`background wake failed (task ${taskID}, device token ${token})`, error))
        )
      );
      return;
    }

    // A push-to-start activity receives its per-activity token asynchronously, after iOS has
    // created it. When the app writes that token back to the task, send one authoritative update
    // with the task's current start date. This both verifies the update channel and repairs an
    // already-created activity if its initial state was stale.
    if (
      wasRunning &&
      runningStart &&
      after.liveActivityPushToken &&
      after.liveActivityPushToken !== before.liveActivityPushToken
    ) {
      await sendLiveActivityUpdate(credentials(), after.liveActivityPushToken, contentState(runningStart)).catch((error) =>
        console.error(`initial Live Activity update failed (task ${taskID})`, error)
      );
      return;
    }

    if (wasRunning && !runningStart && before.liveActivityPushToken) {
      const beforeStart = activeTimerStart(before, now) ?? now;
      const creds = credentials();
      const state = contentState(beforeStart);
      await sendLiveActivityEnd(creds, before.liveActivityPushToken, state).catch((error) =>
        console.error(`end push failed (task ${taskID})`, error)
      );
    }
  }
);

/**
 * Covers the install/reinstall race: a task can already be running when a newly installed iPhone
 * first uploads its push-to-start token. In that case there is no task state transition left for
 * `onTaskTimerChanged` to observe, so start the most recently active task as soon as this device
 * becomes addressable by APNs.
 */
export const onDevicePushToStartTokenChanged = onDocumentWritten(
  {
    document: "users/{uid}/devices/{deviceID}",
    secrets: [APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID],
  },
  async (event) => {
    const before = event.data?.before.data() as DeviceDoc | undefined;
    const after = event.data?.after.data() as DeviceDoc | undefined;
    const token = after?.activityPushToStartToken;
    if (!token || token === before?.activityPushToStartToken) return;

    const { uid, deviceID } = event.params;
    const now = new Date();
    const tasksSnap = await db.collection("users").doc(uid).collection("tasks").get();
    const activeTasks: Array<{ taskID: string; task: TaskDoc; startedAt: Date }> = [];
    for (const doc of tasksSnap.docs) {
      const task = doc.data() as TaskDoc;
      const startedAt = activeTimerStart(task, now);
      if (startedAt) activeTasks.push({ taskID: doc.id, task, startedAt });
    }
    activeTasks.sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime());
    const active = activeTasks[0];
    if (!active) return;

    const attributes = {
      taskID: active.taskID,
      taskName: active.task.name ?? "",
      colorHex: active.task.colorHex ?? "#8CD616",
    };
    await sendLiveActivityStart(credentials(), token, ATTRIBUTES_TYPE, attributes, contentState(active.startedAt))
      .then(() => console.log(`catch-up push-to-start sent OK (task ${active.taskID}, device ${deviceID})`))
      .catch(async (error) => {
        console.error(`catch-up push-to-start failed (device ${deviceID})`, error);
        if (String(error?.message ?? error).includes("410")) {
          await event.data?.after.ref.update({ activityPushToStartToken: admin.firestore.FieldValue.delete() });
        }
      });
  }
);

/**
 * Closes the one gap `onTaskTimerChanged` can't cover: an auto-track grace period
 * (`autoTrackLiveUntil`) elapsing purely by wall-clock time, with no new Firestore write to
 * trigger the update handler above — e.g. the tracking device stopped sending updates and every
 * device running TimeGrow is backgrounded/closed. Sweeps every task with a live push token every
 * few minutes and ends any that are no longer actually running. While a task is active, it also
 * sends the next 60-second progress window so the expanded Dynamic Island ring keeps sweeping
 * even when every app scene is closed.
 *
 * Requires a Firestore collection-group single-field index exemption for `tasks`/
 * `liveActivityPushToken` (ascending) — set via Firestore Console → Indexes → Automatic index
 * settings → Exemptions, not `firestore.indexes.json` (Firestore rejects it as an unnecessary
 * composite index).
 */
export const refreshLiveActivities = onSchedule(
  { schedule: "every 1 minutes", secrets: [APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID] },
  async () => {
    const now = new Date();
    const snap = await db.collectionGroup("tasks").where("liveActivityPushToken", "!=", null).get();
    if (snap.empty) return;

    const creds = credentials();
    await Promise.all(
      snap.docs.map(async (doc) => {
        const task = doc.data() as TaskDoc;
        const token = task.liveActivityPushToken;
        if (!token) return;
        const runningStart = activeTimerStart(task, now);
        if (runningStart) {
          await sendLiveActivityUpdate(creds, token, contentState(runningStart, now)).catch((error) =>
            console.error(`minute-window update failed (${doc.ref.path})`, error)
          );
          return;
        }

        await sendLiveActivityEnd(creds, token, contentState(now)).catch((error) =>
          console.error(`scheduled end push failed (${doc.ref.path})`, error)
        );
        await doc.ref.update({ liveActivityPushToken: admin.firestore.FieldValue.delete() });
      })
    );
  }
);
