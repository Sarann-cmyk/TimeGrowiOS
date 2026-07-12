import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onSchedule } from "firebase-functions/v2/scheduler";
import { defineSecret } from "firebase-functions/params";
import * as admin from "firebase-admin";
import type { Timestamp } from "firebase-admin/firestore";
import {
  sendBackgroundWake,
  sendLiveActivityEnd,
  sendLiveActivityStart,
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
 * Swift's synthesized `Codable` for `Date` decodes the default `.deferredToDate` strategy, which
 * ActivityKit's push content decoder uses — a JSON *number* of seconds since 1970, NOT an ISO8601
 * string. Sending ISO strings here makes the push payload fail to decode on-device silently (no
 * error surfaces server-side; the activity just never starts/updates).
 */
function contentState(startedAt: Date): Record<string, number> {
  return { startedAt: startedAt.getTime() / 1000 };
}

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

      // Primary path: silently wake the app so it runs the already-proven local
      // `LiveActivityManager.reconcile()` instead of relying on push-to-start, which
      // acknowledges pushes but doesn't reliably materialize the activity on-device.
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

      // Secondary/best-effort path: push-to-start directly, in case it succeeds too.
      const startTokens = devicesSnap.docs
        .map((doc) => doc.get("activityPushToStartToken") as string | undefined)
        .filter((token): token is string => !!token);
      if (startTokens.length > 0) {
        const state = contentState(runningStart);
        const attributes = {
          taskID,
          taskName: after.name ?? "",
          colorHex: after.colorHex ?? "#8CD616",
        };
        await Promise.all(
          startTokens.map((token) =>
            sendLiveActivityStart(creds, token, ATTRIBUTES_TYPE, attributes, state).catch((error) =>
              console.error(`push-to-start failed (task ${taskID}, device token ${token})`, error)
            )
          )
        );
      }
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
 * Closes the one gap `onTaskTimerChanged` can't cover: an auto-track grace period
 * (`autoTrackLiveUntil`) elapsing purely by wall-clock time, with no new Firestore write to
 * trigger the update handler above — e.g. the tracking device stopped sending updates and every
 * device running TimeGrow is backgrounded/closed. Sweeps every task with a live push token every
 * few minutes and ends any that are no longer actually running. No longer needs to run every
 * minute now that the Dynamic Island shows plain elapsed-time digits (`Text(timerInterval:)`,
 * set once at start, ticks on its own for 24h) instead of a per-minute-resetting ring — ending
 * stale activities promptly is a courtesy, not something the UI depends on staying fresh.
 *
 * Requires a Firestore collection-group single-field index exemption for `tasks`/
 * `liveActivityPushToken` (ascending) — set via Firestore Console → Indexes → Automatic index
 * settings → Exemptions, not `firestore.indexes.json` (Firestore rejects it as an unnecessary
 * composite index).
 */
export const refreshLiveActivities = onSchedule(
  { schedule: "every 5 minutes", secrets: [APNS_AUTH_KEY, APNS_KEY_ID, APNS_TEAM_ID] },
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
        if (activeTimerStart(task, now) !== null) return;

        await sendLiveActivityEnd(creds, token, contentState(now)).catch((error) =>
          console.error(`scheduled end push failed (${doc.ref.path})`, error)
        );
        await doc.ref.update({ liveActivityPushToken: admin.firestore.FieldValue.delete() });
      })
    );
  }
);
