//
//  AutoTrackPresentationState.swift
//  TimeGrow
//

import Foundation

/// UI-only state for the gap between the short Dynamic Island lease and the longer session
/// merge window. It never writes tracking data or changes which Firestore session is reused.
struct AutoTrackPresentationState {
    enum Phase: String {
        case active
        case paused
    }

    let session: TaskTimeSession
    let phase: Phase
    /// The wall-clock instant used by elapsed rings and provisional duration labels. It advances
    /// while active and freezes at the ActivityKit deadline while paused.
    let displayDate: Date

    var isActive: Bool { phase == .active }
    var isPaused: Bool { phase == .paused }

    static func resolve(task: TGTask, sessions: [TaskTimeSession], at date: Date) -> Self? {
        guard let session = sessions
            .filter({ session in
                guard session.startedAutomatically == true,
                      let endedAt = session.endedAt else { return false }
                if let stoppedAt = task.autoTrackStoppedAt, endedAt <= stoppedAt { return false }
                return date.timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
            })
            .max(by: { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }),
              let confirmedUsageAt = session.endedAt else {
            return nil
        }

        let activityUntil = task.autoTrackLiveActivityUntil
            ?? task.autoTrackLastUsageAt?.addingTimeInterval(autoTrackingLiveActivityGraceSeconds)
            ?? task.autoTrackLiveUntil
        let wasExplicitlyStopped = task.autoTrackSessionStartedAt.flatMap { autoStart in
            task.autoTrackStoppedAt.map { $0 >= autoStart }
        } ?? false

        if let activityUntil, activityUntil > date, !wasExplicitlyStopped {
            return Self(session: session, phase: .active, displayDate: date)
        }

        // Never freeze before the last confirmed threshold. Under normal current-format data the
        // ActivityKit deadline is 90 seconds later; `max` only protects migrated/stale documents.
        let frozenAt = max(confirmedUsageAt, min(activityUntil ?? confirmedUsageAt, date))
        return Self(session: session, phase: .paused, displayDate: frozenAt)
    }
}

/// Deduplicates diagnostics emitted by rapidly updating SwiftUI timer views. The views report on
/// every relevant phase identity, but the export receives only one pause/resume/end transition —
/// never one line per animation frame.
@MainActor
enum AutoTrackPresentationDiagnostics {
    private struct Snapshot: Equatable {
        let cycleID: String
        let phase: String
    }

    private static var lastSnapshotByTaskID: [String: Snapshot] = [:]

    static func key(task: TGTask, presentation: AutoTrackPresentationState?) -> String {
        let cycleID = task.autoTrackLiveActivityCycleID
            ?? presentation?.session.id
            ?? "no-cycle"
        return "\(cycleID)|\(presentation?.phase.rawValue ?? "inactive")"
    }

    static func report(
        task: TGTask,
        presentation: AutoTrackPresentationState?,
        surface: String,
        at date: Date
    ) {
        guard let taskID = task.id else { return }
        let cycleID = task.autoTrackLiveActivityCycleID
            ?? presentation?.session.id
            ?? "no-cycle"
        let phase = presentation?.phase.rawValue ?? "inactive"
        let snapshot = Snapshot(cycleID: cycleID, phase: phase)
        let previous = lastSnapshotByTaskID[taskID]
        guard previous != snapshot else { return }
        lastSnapshotByTaskID[taskID] = snapshot

        if presentation?.isPaused == true {
            let remaining = task.autoTrackLiveUntil.map { max(0, Int($0.timeIntervalSince(date))) }
            DiagnosticsLog.log(
                "autoTrackUI",
                "paused blinking started task=\(task.name) taskID=\(taskID) surface=\(surface) cycle=\(cycleID) leaseUntil=\(String(describing: task.autoTrackLiveActivityUntil)) mergeUntil=\(String(describing: task.autoTrackLiveUntil)) remainingReturnSeconds=\(String(describing: remaining)) frozenAt=\(String(describing: presentation?.displayDate))"
            )
            return
        }

        if previous?.phase == AutoTrackPresentationState.Phase.paused.rawValue {
            let reason = presentation?.isActive == true ? "usageResumed" : "returnWindowEndedOrStopped"
            DiagnosticsLog.log(
                "autoTrackUI",
                "paused blinking ended task=\(task.name) taskID=\(taskID) surface=\(surface) previousCycle=\(previous?.cycleID ?? "?") currentCycle=\(cycleID) reason=\(reason) phase=\(phase)"
            )
        }
    }
}
