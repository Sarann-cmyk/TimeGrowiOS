//
//  LiveActivityManager.swift
//  TimeGrow
//

import ActivityKit
import Foundation
import UIKit

/// Keeps ActivityKit Live Activities in sync with each task's running timer (manual or
/// auto-tracked). Call `reconcile(tasks:)` whenever `TaskService.tasks` changes; it starts
/// activities for newly running tasks and ends activities for tasks that stopped running.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    /// Ticks while at least one activity is running so an auto-tracked activity whose grace
    /// period (`autoTrackLiveUntil`) elapses purely by wall-clock time — with no new Firestore
    /// write to trigger `TaskService.tasks`' `didSet` — still gets re-checked and ended promptly.
    private var recheckTimer: Timer?
    /// Fires exactly at each local minute boundary while the app is alive. Keeping this separate
    /// from the 30-second lifecycle recheck prevents the expanded progress ring from waiting up
    /// to half a minute after completing a sweep before its next 60-second interval arrives.
    private var minuteProgressTimer: Timer?
    private var lastKnownTasks: [TGTask] = []
    private var lastMinuteWindowStart: Date?

    /// Receives activities created by ActivityKit itself, notably a remote push-to-start. Merely
    /// scanning `activities` during a background wake can race the system creating that activity;
    /// this stream guarantees we subscribe to its per-activity push-token as soon as it exists.
    private var activityUpdatesTask: Task<Void, Never>?

    /// Start-token registration must begin during app launch, before a SwiftUI scene appears.
    /// ActivityKit may yield the token only once; losing that early update means a server cannot
    /// start a Dynamic Island activity later while the app is closed.
    private var pushToStartTokenUpdatesTask: Task<Void, Never>?
    private var latestPushToStartToken: String?

    /// Tracks the system-level Live Activities toggle (Settings > Face ID & Passcode >
    /// Live Activities, or per-app). A user flipping this off is the single most common reason
    /// the Dynamic Island silently never appears while everything else keeps working.
    private var activityEnablementUpdatesTask: Task<Void, Never>?

    /// Activities whose push token stream we've already subscribed to, keyed by `Activity.id`.
    /// Needed because `reconcile(tasks:)` can discover an activity it didn't start itself (e.g.
    /// `AutoTrackingExtension` starts activities directly, bypassing `start(for:startedAt:)`
    /// below) — without this, that activity's `liveActivityPushToken` never reaches Firestore,
    /// so a remote `end` push (sent when another device stops the task) has nothing to target
    /// and the Dynamic Island silently keeps counting until the app is opened locally.
    private var observedActivityIDs: Set<String> = []
    /// Firestore can briefly expose an incomplete/intermediate task document while concurrent
    /// auto-track, push-token and timer writes are being merged. Ending an Activity immediately
    /// from that one snapshot causes a visible Dynamic Island flicker even when the following
    /// snapshot still says the task is running. Keep the end reversible for this short window.
    private var pendingEndTasksByActivityID: [String: Task<Void, Never>] = [:]
    /// A push-to-start activity may arrive just before the background wake has fetched its task
    /// state. Do not end it based on that short-lived stale snapshot; give the server state one
    /// reconciliation interval to arrive first.
    private var remoteStartGraceUntilByActivityID: [String: Date] = [:]

    private let remoteStartReconciliationGrace: TimeInterval = 30

    /// Called whenever a task's per-activity push token becomes known (activity just started) or
    /// should be cleared (activity ending). Set once from `TimeGrowApp` to persist it via
    /// `TaskService`, so this manager doesn't need a `TaskService` reference of its own.
    var pushTokenHandler: ((_ taskID: String, _ token: String?) -> Void)?

    /// Persists the device-level token in Firestore through `TaskService` once it is available.
    /// If the token arrived before Firebase/auth/UI setup completed, assigning this handler still
    /// immediately receives the cached value.
    var pushToStartTokenHandler: ((_ token: String) -> Void)? {
        didSet {
            if let latestPushToStartToken {
                pushToStartTokenHandler?(latestPushToStartToken)
            }
        }
    }

    private init() {}

    /// Begin this at application launch alongside the other observers below. Logs the current
    /// enablement immediately, then every subsequent flip, so a report of "it just stopped
    /// appearing" can be cross-checked against whether the user (or a Focus mode) disabled Live
    /// Activities system-wide, versus a bug in our own start/end logic.
    func startObservingActivityEnablement() {
        guard activityEnablementUpdatesTask == nil else { return }
        let info = ActivityAuthorizationInfo()
        DiagnosticsLog.log(
            "liveActivity",
            "Live Activities authorization enabled=\(info.areActivitiesEnabled) frequentPushesEnabled=\(info.frequentPushesEnabled)"
        )
        activityEnablementUpdatesTask = Task {
            for await enabled in info.activityEnablementUpdates {
                DiagnosticsLog.log("liveActivity", "Live Activities authorization changed enabled=\(enabled)")
            }
        }
    }

    /// Begin this at application launch, not from a view `.task`. The app must still be opened
    /// once after installation for iOS to issue a token, but afterwards the server can start
    /// activities while TimeGrow has no open scene.
    func startObservingPushToStartTokens() {
        guard pushToStartTokenUpdatesTask == nil else { return }
        pushToStartTokenUpdatesTask = Task { [weak self] in
            for await data in Activity<TimeGrowLiveActivityAttributes>.pushToStartTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    guard let self else { return }
                    self.latestPushToStartToken = token
                    self.pushToStartTokenHandler?(token)
                    DiagnosticsLog.log("liveActivity", "Received push-to-start token")
                }
            }
        }
    }

    /// Start once after `pushTokenHandler` has been wired to `TaskService`. The activity token
    /// obtained here is essential for a server-side `end` push when auto-tracking later expires
    /// while the app remains closed.
    func startObservingActivityUpdates() {
        guard activityUpdatesTask == nil else { return }
        activityUpdatesTask = Task { [weak self] in
            for await activity in Activity<TimeGrowLiveActivityAttributes>.activityUpdates {
                await MainActor.run {
                    guard let self else { return }
                    let taskID = activity.attributes.taskID
                    guard !self.observedActivityIDs.contains(activity.id) else { return }
                    self.observedActivityIDs.insert(activity.id)
                    if UIApplication.shared.applicationState != .active {
                        self.remoteStartGraceUntilByActivityID[activity.id] = Date()
                            .addingTimeInterval(self.remoteStartReconciliationGrace)
                    }
                    self.observePushToken(of: activity, taskID: taskID)
                    DiagnosticsLog.log("liveActivity", "Observed ActivityKit-created activity task=\(taskID)")
                }
            }
        }
    }

    func reconcile(tasks: [TGTask]) {
        lastKnownTasks = tasks
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            DiagnosticsLog.log("liveActivity", "reconcile skipped: Live Activities not enabled")
            return
        }

        var runningStartByTaskID: [String: Date] = [:]
        for task in tasks {
            guard let id = task.id, let startedAt = Self.activeTimerStart(for: task) else { continue }
            runningStartByTaskID[id] = startedAt
        }
        let existingActivitySummary = Activity<TimeGrowLiveActivityAttributes>.activities.map {
            "\($0.attributes.taskID):\($0.activityState)"
        }
        DiagnosticsLog.log("liveActivity", "reconcile tasks=\(tasks.count) running=\(runningStartByTaskID.keys) existingActivities=\(existingActivitySummary)")

        for activity in Activity<TimeGrowLiveActivityAttributes>.activities {
            let taskID = activity.attributes.taskID
            guard runningStartByTaskID[taskID] != nil else {
                if UIApplication.shared.applicationState != .active,
                   let graceUntil = remoteStartGraceUntilByActivityID[activity.id],
                   graceUntil > Date() {
                    DiagnosticsLog.log(
                        "liveActivity",
                        "Preserving recent push-start activity task=\(taskID) while waiting for server state"
                    )
                    continue
                }

                scheduleEndAfterReconciliationGrace(for: activity, taskID: taskID)
                continue
            }
            remoteStartGraceUntilByActivityID.removeValue(forKey: activity.id)
            cancelPendingEnd(forActivityID: activity.id)
            if !observedActivityIDs.contains(activity.id) {
                observedActivityIDs.insert(activity.id)
                observePushToken(of: activity, taskID: taskID)
            }
            runningStartByTaskID.removeValue(forKey: taskID)
        }

        refreshMinuteProgress(for: tasks)

        // `Activity.request()` throws "Target is not foreground" whenever called outside the
        // foreground (confirmed on-device 2026-07-14) — a hard ActivityKit rule, not a
        // reliability quirk. `reconcile()` runs here from a background-wake push too, where this
        // would always fail; skipping it there avoids a guaranteed failure on every wake (and the
        // log noise from repeating it). Starting a *new* activity while backgrounded is handled
        // by push-to-start server-side instead (`onTaskTimerChanged` in Cloud Functions) — the
        // one Apple-sanctioned exception, since the system creates the activity directly without
        // running app code. Ending existing activities above isn't gated the same way; only
        // starting new ones is foreground-restricted.
        if UIApplication.shared.applicationState == .active {
            for task in tasks {
                guard let id = task.id, let startedAt = runningStartByTaskID[id] else { continue }
                start(for: task, startedAt: startedAt)
            }
        }

        updateTimerScheduling()
    }

    /// Wait briefly before ending an activity from a non-running snapshot. A subsequent
    /// reconciliation cancels this task if that snapshot was only a transient merge state.
    private func scheduleEndAfterReconciliationGrace(
        for activity: Activity<TimeGrowLiveActivityAttributes>,
        taskID: String
    ) {
        guard pendingEndTasksByActivityID[activity.id] == nil else { return }

        let activityID = activity.id
        DiagnosticsLog.log(
            "liveActivity",
            "Deferring Live Activity end task=\(taskID) id=\(activityID) while confirming stopped state"
        )
        pendingEndTasksByActivityID[activityID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            self.pendingEndTasksByActivityID.removeValue(forKey: activityID)

            let taskIsStillRunning = self.lastKnownTasks.contains {
                $0.id == taskID && Self.activeTimerStart(for: $0) != nil
            }
            guard !taskIsStillRunning else {
                DiagnosticsLog.log(
                    "liveActivity",
                    "Cancelled deferred end task=\(taskID) id=\(activityID); task resumed in later snapshot"
                )
                return
            }

            guard let currentActivity = Activity<TimeGrowLiveActivityAttributes>.activities.first(where: {
                $0.id == activityID
            }) else {
                return
            }

            self.remoteStartGraceUntilByActivityID.removeValue(forKey: activityID)
            self.observedActivityIDs.remove(activityID)
            self.pushTokenHandler?(taskID, nil)
            // Surface why `activeTimerStart` returned nil for this task, so a report of "the
            // Dynamic Island vanished mid-use" can be matched against the exact auto-track state
            // (grace window expired vs. an explicit stop vs. never live) without re-deriving it
            // from separate task-snapshot log lines.
            let staleTask = self.lastKnownTasks.first { $0.id == taskID }
            DiagnosticsLog.log(
                "liveActivity",
                "Ending Live Activity task=\(taskID) id=\(activityID) after reconciliation grace autoTrackLiveUntil=\(String(describing: staleTask?.autoTrackLiveUntil)) autoTrackStoppedAt=\(String(describing: staleTask?.autoTrackStoppedAt)) autoTrackSessionStartedAt=\(String(describing: staleTask?.autoTrackSessionStartedAt))"
            )
            await currentActivity.end(nil, dismissalPolicy: .immediate)
            DiagnosticsLog.log("liveActivity", "Ended Live Activity task=\(taskID) id=\(activityID)")
        }
    }

    private func cancelPendingEnd(forActivityID activityID: String) {
        guard let pendingEnd = pendingEndTasksByActivityID.removeValue(forKey: activityID) else { return }
        pendingEnd.cancel()
        DiagnosticsLog.log("liveActivity", "Cancelled deferred end id=\(activityID); task is running")
    }

    private func start(for task: TGTask, startedAt: Date) {
        guard let taskID = task.id else { return }
        let attributes = TimeGrowLiveActivityAttributes(taskID: taskID, taskName: task.name, colorHex: task.colorHex)
        let contentState = TimeGrowLiveActivityAttributes.ContentState(
            startedAt: startedAt,
            minuteWindowStart: Self.minuteWindowStart(for: Date())
        )

        do {
            // A Live Activity created locally must explicitly opt in to ActivityKit push
            // updates. Without `.token`, `pushTokenUpdates` has no token to deliver and the
            // server cannot end the activity while this app is suspended.
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: contentState, staleDate: nil),
                pushType: .token
            )
            observedActivityIDs.insert(activity.id)
            observePushToken(of: activity, taskID: taskID)
            DiagnosticsLog.log(
                "liveActivity",
                "Started Live Activity for \(task.name) id=\(activity.id) state=\(activity.activityState)"
            )
        } catch {
            DiagnosticsLog.log("liveActivity", "Failed to start Live Activity for \(task.name): \(error.localizedDescription)")
        }
        updateTimerScheduling()
    }

    /// Streams this activity's per-activity push token to `pushTokenHandler` as ActivityKit
    /// (re)issues it, so a server can push `end` events via APNs.
    private func observePushToken(of activity: Activity<TimeGrowLiveActivityAttributes>, taskID: String) {
        Task { [weak self] in
            // `activityUpdates` can hand us an activity after ActivityKit already issued its
            // token. Read the current value before waiting for a later rotation so we never
            // miss that initial token.
            if let data = activity.pushToken {
                let hexToken = data.map { String(format: "%02x", $0) }.joined()
                self?.pushTokenHandler?(taskID, hexToken)
                DiagnosticsLog.log("liveActivity", "Stored current per-activity push token task=\(taskID)")
            }
            for await data in activity.pushTokenUpdates {
                let hexToken = data.map { String(format: "%02x", $0) }.joined()
                self?.pushTokenHandler?(taskID, hexToken)
                DiagnosticsLog.log("liveActivity", "Received per-activity push token task=\(taskID)")
            }
        }
        observeActivityState(of: activity, taskID: taskID)
    }

    /// Surfaces ActivityKit's own lifecycle for this activity (`active`/`stale`/`ended`/
    /// `dismissed`) as it happens. This is what actually explains a Dynamic Island that goes
    /// quiet or drops to its minimal presentation while the lock screen entry — driven by the
    /// same activity, just rendered differently — keeps counting: the state transition shows up
    /// here even though nothing on screen says why.
    private func observeActivityState(of activity: Activity<TimeGrowLiveActivityAttributes>, taskID: String) {
        Task {
            DiagnosticsLog.log(
                "liveActivity",
                "Activity state task=\(taskID) id=\(activity.id) state=\(activity.activityState)"
            )
            for await state in activity.activityStateUpdates {
                DiagnosticsLog.log(
                    "liveActivity",
                    "Activity state changed task=\(taskID) id=\(activity.id) state=\(state)"
                )
            }
        }
    }

    /// Starts or stops the periodic re-check based on whether any activity is running.
    private func updateTimerScheduling() {
        let hasActivities = !Activity<TimeGrowLiveActivityAttributes>.activities.isEmpty
        if hasActivities, recheckTimer == nil {
            recheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.reconcile(tasks: self.lastKnownTasks)
                }
            }
        }

        if hasActivities {
            scheduleMinuteProgressRefresh()
        } else {
            recheckTimer?.invalidate()
            recheckTimer = nil
            minuteProgressTimer?.invalidate()
            minuteProgressTimer = nil
        }
    }

    /// Schedule the next refresh against the wall-clock minute, not against when the activity
    /// happened to start. `ProgressView(timerInterval:)` then receives the new range as the old
    /// one ends, making the ring repeat without a visible full-ring pause in the foreground app.
    private func scheduleMinuteProgressRefresh() {
        guard minuteProgressTimer == nil else { return }

        let now = Date()
        let nextMinute = Self.minuteWindowStart(for: now).addingTimeInterval(60)
        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshMinuteProgress(for: self.lastKnownTasks)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteProgressTimer = timer
    }

    /// `ProgressView(timerInterval:)` animates smoothly inside WidgetKit, but needs a fresh
    /// 60-second range at each minute boundary to begin its next sweep.
    private func refreshMinuteProgress(for tasks: [TGTask]) {
        let minuteStart = Self.minuteWindowStart(for: Date())
        guard minuteStart != lastMinuteWindowStart else { return }
        lastMinuteWindowStart = minuteStart

        let startsByTaskID = Dictionary(uniqueKeysWithValues: tasks.compactMap { task -> (String, Date)? in
            guard let id = task.id, let startedAt = Self.activeTimerStart(for: task) else { return nil }
            return (id, startedAt)
        })
        for activity in Activity<TimeGrowLiveActivityAttributes>.activities {
            guard let startedAt = startsByTaskID[activity.attributes.taskID] else { continue }
            let state = TimeGrowLiveActivityAttributes.ContentState(
                startedAt: startedAt,
                minuteWindowStart: minuteStart
            )
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        }
    }

    private static func minuteWindowStart(for date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private static func activeTimerStart(for task: TGTask) -> Date? {
        if let manualStart = task.timerStartedAt {
            return manualStart
        }
        if let autoStart = task.autoTrackSessionStartedAt,
           let liveUntil = task.autoTrackLiveUntil,
           liveUntil > Date(),
           !(task.autoTrackStoppedAt.map { $0 >= autoStart } ?? false) {
            return autoStart
        }
        return nil
    }
}
