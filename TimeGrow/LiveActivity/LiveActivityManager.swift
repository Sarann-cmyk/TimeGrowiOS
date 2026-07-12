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

    private init() {}

    func reconcile(tasks: [TGTask]) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        var runningStartByTaskID: [String: Date] = [:]
        for task in tasks {
            guard let id = task.id, let startedAt = Self.activeTimerStart(for: task) else { continue }
            runningStartByTaskID[id] = startedAt
        }

        for activity in Activity<TimeGrowLiveActivityAttributes>.activities {
            let taskID = activity.attributes.taskID
            guard let startedAt = runningStartByTaskID[taskID] else {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                continue
            }
            if activity.content.state.startedAt != startedAt {
                let updated = TimeGrowLiveActivityAttributes.ContentState(startedAt: startedAt)
                Task { await activity.update(.init(state: updated, staleDate: nil)) }
            }
            runningStartByTaskID.removeValue(forKey: taskID)
        }

        for task in tasks {
            guard let id = task.id, let startedAt = runningStartByTaskID[id] else { continue }
            start(for: task, startedAt: startedAt)
        }
    }

    private func start(for task: TGTask, startedAt: Date) {
        guard let taskID = task.id else { return }
        let attributes = TimeGrowLiveActivityAttributes(taskID: taskID, taskName: task.name, colorHex: task.colorHex)
        let contentState = TimeGrowLiveActivityAttributes.ContentState(startedAt: startedAt)

        do {
            _ = try Activity.request(attributes: attributes, content: .init(state: contentState, staleDate: nil))
        } catch {
            DiagnosticsLog.log("liveActivity", "Failed to start Live Activity for \(task.name): \(error.localizedDescription)")
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
