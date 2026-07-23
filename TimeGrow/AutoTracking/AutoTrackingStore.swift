//
//  AutoTrackingStore.swift
//  TimeGrow
//

import Combine
import CryptoKit
import DeviceActivity
import FamilyControls
import Foundation

// Must match the App Group entitlement on both the app and the
// AutoTrackingExtension targets, and the suite name the extension writes to.
let autoTrackingAppGroupID = "group.WINNER.ltd.TimeGrow"
let autoTrackingThresholdSeconds: TimeInterval = 60
/// How long a gap since the last confirmed minute of usage is still treated as the same
/// session (same Firestore session record, same live Live Activity). DeviceActivityMonitor's
/// `eventDidReachThreshold` delivery has no documented upper bound on latency — it's best-effort,
/// and 180s proved too short: a genuinely continuous TikTok session on 2026-07-21 saw iOS defer
/// delivery for 299s, splitting one session into two and dropping the Dynamic Island mid-use.
/// 300s comfortably covers the delays observed so far without being so long it risks merging
/// genuinely separate sessions.
let autoTrackingInactivityGraceSeconds: TimeInterval = 300
/// Sessions shorter than this when stopped are discarded outright (deleted, not just
/// hidden) — they're accidental taps or auto-tracking blips, not real tracked time.
let minimumTrackedSessionDuration: TimeInterval = 3
private let pendingEventsKey = "autoTracking.pendingEvents"
private let debugEventsKey = "autoTracking.debugEvents"
private let selectionDataKeyPrefix = "autoTracking.selectionData."
private let monitoredActivityKeyPrefix = "autoTracking.monitoredActivity."
private let minimumDistinctPendingEventInterval: TimeInterval = 55

struct PendingAutoTrackEvent {
    let taskID: String
    let occurredAt: Date
}

@MainActor
final class AutoTrackingStore: ObservableObject {
    @Published private(set) var authorizationStatus: AuthorizationStatus = AuthorizationCenter.shared.authorizationStatus

    private let center = AuthorizationCenter.shared
    private let activityCenter = DeviceActivityCenter()
    private let defaults = UserDefaults.standard
    private var monitoredActivitiesByTaskID: [String: DeviceActivityName] = [:]
    private var didResetMonitoringThisRun = false

    func refreshAuthorizationStatus() {
        authorizationStatus = center.authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            try await center.requestAuthorization(for: .individual)
        } catch {
            print("Screen Time authorization failed: \(error.localizedDescription)")
        }
        refreshAuthorizationStatus()
        return authorizationStatus == .approved
    }

    func selection(for taskID: String) -> FamilyActivitySelection {
        guard let data = defaults.data(forKey: selectionKey(for: taskID)),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data) else {
            return FamilyActivitySelection()
        }
        return decoded
    }

    func saveSelection(_ selection: FamilyActivitySelection, for taskID: String) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        defaults.set(data, forKey: selectionKey(for: taskID))
        UserDefaults(suiteName: autoTrackingAppGroupID)?.set(data, forKey: sharedSelectionKey(for: taskID))
        scheduleMonitoring(selection: selection, taskID: taskID)
    }

    func hasSelection(for taskID: String) -> Bool {
        let current = selection(for: taskID)
        return !current.applicationTokens.isEmpty || !current.categoryTokens.isEmpty || !current.webDomainTokens.isEmpty
    }

    func refreshMonitoring(for tasks: [TGTask]) {
        guard authorizationStatus == .approved else { return }
        guard !tasks.isEmpty else { return }

        if !didResetMonitoringThisRun {
            adoptExistingMonitoring(for: tasks)
            didResetMonitoringThisRun = true
        }

        for task in tasks {
            guard let taskID = task.id else { continue }
            let currentSelection = selection(for: taskID)
            let hasSelection = !currentSelection.applicationTokens.isEmpty || !currentSelection.categoryTokens.isEmpty || !currentSelection.webDomainTokens.isEmpty

            guard hasSelection else {
                stopMonitoring(for: taskID)
                continue
            }

            if task.isTimerRunning {
                stopMonitoring(for: taskID)
            } else if monitoredActivitiesByTaskID[taskID] == nil {
                scheduleMonitoring(selection: currentSelection, taskID: taskID)
            }
        }
    }

    /// On the first `refreshMonitoring` call of a launch, DeviceActivity monitoring the
    /// extension armed before the app was last closed may still be live and mid-way toward its
    /// next 1-minute threshold. Blindly calling `stopMonitoring()` here (as this used to do)
    /// discards that in-flight progress for every auto-tracked task on every cold start, which
    /// compounds into a real chunk of missed usage on days the app gets relaunched often. Adopt
    /// whatever's still genuinely running and matches the task's current selection instead, and
    /// only stop what's actually orphaned (stale generation, cleared selection, deleted task).
    private func adoptExistingMonitoring(for tasks: [TGTask]) {
        let liveActivityNames = Set(activityCenter.activities.map(\.rawValue))
        let sharedDefaults = UserDefaults(suiteName: autoTrackingAppGroupID)

        for task in tasks {
            guard let taskID = task.id, !task.isTimerRunning else { continue }
            let currentSelection = selection(for: taskID)
            let hasSelection = !currentSelection.applicationTokens.isEmpty || !currentSelection.categoryTokens.isEmpty || !currentSelection.webDomainTokens.isEmpty
            guard hasSelection,
                  let storedActivityName = sharedDefaults?.string(forKey: "\(monitoredActivityKeyPrefix)\(taskID)"),
                  storedActivityName.hasPrefix("\(taskID)|"),
                  liveActivityNames.contains(storedActivityName) else { continue }

            monitoredActivitiesByTaskID[taskID] = DeviceActivityName(storedActivityName)
            DiagnosticsLog.log("autoTrack", "adopted live DeviceActivity monitor for task \(taskID) activity=\(storedActivityName)")
        }

        let adoptedNames = Set(monitoredActivitiesByTaskID.values.map(\.rawValue))
        let orphaned = liveActivityNames.subtracting(adoptedNames)
        if !orphaned.isEmpty {
            activityCenter.stopMonitoring(orphaned.map { DeviceActivityName($0) })
            DiagnosticsLog.log("autoTrack", "stopped \(orphaned.count) orphaned DeviceActivity monitor(s) at launch: \(orphaned)")
        }
    }

    private func stopMonitoring(for taskID: String) {
        let inMemoryActivity = monitoredActivitiesByTaskID.removeValue(forKey: taskID)
        let sharedDefaults = UserDefaults(suiteName: autoTrackingAppGroupID)
        let sharedActivity = sharedDefaults
            .flatMap { $0.string(forKey: "\(monitoredActivityKeyPrefix)\(taskID)") }
            .map { DeviceActivityName($0) }
        let activities = [inMemoryActivity, sharedActivity].compactMap { $0 }
        let uniqueActivities = Array(Set(activities.map { $0.rawValue })).map { DeviceActivityName($0) }
        if !uniqueActivities.isEmpty {
            activityCenter.stopMonitoring(uniqueActivities)
            DiagnosticsLog.log("autoTrack", "stopped DeviceActivity monitoring for task \(taskID) activities=\(uniqueActivities.map { $0.rawValue })")
        }
        sharedDefaults?.removeObject(forKey: "\(monitoredActivityKeyPrefix)\(taskID)")
    }

    /// Watches the picked apps/categories all day, every day, and reports
    /// back once the task has been used for at least a minute in a day.
    private func scheduleMonitoring(selection: FamilyActivitySelection, taskID: String) {
        let generation = UUID().uuidString
        let activityName = DeviceActivityName("\(taskID)|\(generation)")
        let thresholdEventName = DeviceActivityEvent.Name("thresholdReached|\(generation)")
        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty else {
            stopMonitoring(for: taskID)
            return
        }

        var selectionDataFingerprint = "?"
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults(suiteName: autoTrackingAppGroupID)?.set(data, forKey: sharedSelectionKey(for: taskID))
            selectionDataFingerprint = Self.fingerprint(for: data)
        }

        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(
            applications: selection.applicationTokens,
            categories: selection.categoryTokens,
            webDomains: selection.webDomainTokens,
            threshold: DateComponents(minute: 1),
            includesPastActivity: false
        )

        do {
            try activityCenter.startMonitoring(activityName, during: schedule, events: [thresholdEventName: event])
            monitoredActivitiesByTaskID[taskID] = activityName
            UserDefaults(suiteName: autoTrackingAppGroupID)?.set(
                activityName.rawValue,
                forKey: "\(monitoredActivityKeyPrefix)\(taskID)"
            )
            DiagnosticsLog.log(
                "autoTrack",
                "started DeviceActivity monitoring for task \(taskID) activity=\(activityName.rawValue) event=\(thresholdEventName.rawValue) apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count) webDomains=\(selection.webDomainTokens.count) selectionFingerprint=\(selectionDataFingerprint)"
            )
        } catch {
            DiagnosticsLog.log("autoTrack", "failed to start DeviceActivity monitoring: \(error.localizedDescription)")
        }
    }

    /// A short, non-reversible fingerprint of the encoded `FamilyActivitySelection`. Apple's
    /// tokens are opaque — we can never log which apps are actually selected — but two tasks
    /// showing the identical fingerprint is direct proof their selections are byte-for-byte the
    /// same (e.g. a picker/save bug duplicating one task's selection into another's), which a
    /// bare token count can't distinguish from "coincidentally the same size."
    static func fingerprint(for data: Data) -> String {
        String(SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined().prefix(8))
    }

    private func selectionKey(for taskID: String) -> String {
        "autoTracking.selection.\(taskID)"
    }

    private func sharedSelectionKey(for taskID: String) -> String {
        "\(selectionDataKeyPrefix)\(taskID)"
    }

    /// Reads and clears the events the AutoTrackingExtension queued in the
    /// shared App Group container since the last time the app checked.
    func drainPendingEvents() -> [PendingAutoTrackEvent] {
        guard let shared = UserDefaults(suiteName: autoTrackingAppGroupID) else { return [] }
        let debugEvents = shared.array(forKey: debugEventsKey) as? [[String: Any]] ?? []
        shared.removeObject(forKey: debugEventsKey)
        for entry in debugEvents {
            let name = entry["name"] as? String ?? "unknown"
            let taskID = entry["taskID"] as? String ?? "unknown"
            let activity = entry["activity"] as? String ?? "unknown"
            let occurredAt = Date(timeIntervalSince1970: entry["occurredAt"] as? Double ?? 0)
            DiagnosticsLog.log("autoTrack", "extension debug: \(name) taskID=\(taskID) activity=\(activity) at=\(occurredAt)")
        }

        let raw = shared.array(forKey: pendingEventsKey) as? [[String: Any]] ?? []
        shared.removeObject(forKey: pendingEventsKey)
        if !raw.isEmpty {
            DiagnosticsLog.log("autoTrack", "drained \(raw.count) pending event(s): \(raw)")
        }

        var events: [PendingAutoTrackEvent] = []
        for entry in raw {
            guard let taskID = entry["taskID"] as? String,
                  let occurredAt = entry["occurredAt"] as? Double else { continue }
            events.append(PendingAutoTrackEvent(taskID: taskID, occurredAt: Date(timeIntervalSince1970: occurredAt)))
        }

        var accepted: [PendingAutoTrackEvent] = []
        var lastAcceptedByTaskID: [String: Date] = [:]
        var discardedDuplicates = 0
        for event in events.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            if let previous = lastAcceptedByTaskID[event.taskID],
               event.occurredAt.timeIntervalSince(previous) < minimumDistinctPendingEventInterval {
                discardedDuplicates += 1
                continue
            }
            lastAcceptedByTaskID[event.taskID] = event.occurredAt
            accepted.append(event)
        }
        if discardedDuplicates > 0 {
            DiagnosticsLog.log("autoTrack", "discarded \(discardedDuplicates) duplicate pending threshold event(s)")
        }
        return accepted
    }
}
