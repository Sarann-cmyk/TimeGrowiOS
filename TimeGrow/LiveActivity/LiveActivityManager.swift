//
//  LiveActivityManager.swift
//  TimeGrow
//

import ActivityKit
import Foundation

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
    private var lastKnownTasks: [TGTask] = []

    /// Called whenever a task's per-activity push token becomes known (activity just started) or
    /// should be cleared (activity ending). Set once from `TimeGrowApp` to persist it via
    /// `TaskService`, so this manager doesn't need a `TaskService` reference of its own.
    var pushTokenHandler: ((_ taskID: String, _ token: String?) -> Void)?

    private init() {}

    /// This device's ActivityKit push-to-start token stream, hex-encoded. A server can use this
    /// token to start a new Live Activity via APNs even while the app isn't running. Available
    /// even when zero activities are currently running.
    var pushToStartTokenUpdates: AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                for await data in Activity<TimeGrowLiveActivityAttributes>.pushToStartTokenUpdates {
                    continuation.yield(data.map { String(format: "%02x", $0) }.joined())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func reconcile(tasks: [TGTask]) {
        lastKnownTasks = tasks
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var runningStartByTaskID: [String: Date] = [:]
        for task in tasks {
            guard let id = task.id, let startedAt = Self.activeTimerStart(for: task) else { continue }
            runningStartByTaskID[id] = startedAt
        }

        for activity in Activity<TimeGrowLiveActivityAttributes>.activities {
            let taskID = activity.attributes.taskID
            guard runningStartByTaskID[taskID] != nil else {
                pushTokenHandler?(taskID, nil)
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            runningStartByTaskID.removeValue(forKey: taskID)
        }

        for task in tasks {
            guard let id = task.id, let startedAt = runningStartByTaskID[id] else { continue }
            start(for: task, startedAt: startedAt)
        }

        updateTimerScheduling()
    }

    private func start(for task: TGTask, startedAt: Date) {
        guard let taskID = task.id else { return }
        let attributes = TimeGrowLiveActivityAttributes(taskID: taskID, taskName: task.name, colorHex: task.colorHex)
        let contentState = TimeGrowLiveActivityAttributes.ContentState(startedAt: startedAt)

        do {
            let activity = try Activity.request(attributes: attributes, content: .init(state: contentState, staleDate: nil))
            observePushToken(of: activity, taskID: taskID)
        } catch {
            DiagnosticsLog.log("liveActivity", "Failed to start Live Activity for \(task.name): \(error.localizedDescription)")
        }
        updateTimerScheduling()
    }

    /// Streams this activity's per-activity push token to `pushTokenHandler` as ActivityKit
    /// (re)issues it, so a server can push `end` events via APNs.
    private func observePushToken(of activity: Activity<TimeGrowLiveActivityAttributes>, taskID: String) {
        Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let hexToken = data.map { String(format: "%02x", $0) }.joined()
                self?.pushTokenHandler?(taskID, hexToken)
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
        } else if !hasActivities {
            recheckTimer?.invalidate()
            recheckTimer = nil
        }
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
