//
//  AutoTrackingStore.swift
//  TimeGrow
//

import Combine
import DeviceActivity
import FamilyControls
import Foundation

// Must match the App Group entitlement on both the app and the
// AutoTrackingExtension targets, and the suite name the extension writes to.
let autoTrackingAppGroupID = "group.WINNER.ltd.TimeGrow"
let autoTrackingThresholdSeconds: TimeInterval = 60
let autoTrackingInactivityGraceSeconds: TimeInterval = 120
private let pendingEventsKey = "autoTracking.pendingEvents"
private let debugEventsKey = "autoTracking.debugEvents"
private let selectionDataKeyPrefix = "autoTracking.selectionData."

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
            activityCenter.stopMonitoring()
            monitoredActivitiesByTaskID = [:]
            didResetMonitoringThisRun = true
            print("Reset all DeviceActivity monitoring for this app run")
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

    private func stopMonitoring(for taskID: String) {
        guard let activityName = monitoredActivitiesByTaskID.removeValue(forKey: taskID) else { return }
        activityCenter.stopMonitoring([activityName])
        print("Stopped DeviceActivity monitoring for task \(taskID) activity=\(activityName.rawValue)")
    }

    /// Watches the picked apps/categories all day, every day, and reports
    /// back once the task has been used for at least a minute in a day.
    private func scheduleMonitoring(selection: FamilyActivitySelection, taskID: String) {
        let generation = Int(Date().timeIntervalSince1970)
        let activityName = DeviceActivityName("\(taskID)|\(generation)")
        let thresholdEventName = DeviceActivityEvent.Name("thresholdReached|\(generation)")
        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty else {
            stopMonitoring(for: taskID)
            return
        }

        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults(suiteName: autoTrackingAppGroupID)?.set(data, forKey: sharedSelectionKey(for: taskID))
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
            print(
                "Started DeviceActivity monitoring for task \(taskID) activity=\(activityName.rawValue) event=\(thresholdEventName.rawValue) apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count)"
            )
        } catch {
            print("Failed to start DeviceActivity monitoring: \(error.localizedDescription)")
        }
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
            print("DeviceActivity debug: \(name) task=\(taskID) activity=\(activity) at=\(occurredAt)")
        }

        let raw = shared.array(forKey: pendingEventsKey) as? [[String: Any]] ?? []
        shared.removeObject(forKey: pendingEventsKey)
        if !raw.isEmpty {
            print("Drained \(raw.count) pending auto-track event(s)")
        }

        var uniqueEvents: [String: PendingAutoTrackEvent] = [:]
        for entry in raw {
            guard let taskID = entry["taskID"] as? String,
                  let occurredAt = entry["occurredAt"] as? Double else { continue }
            let event = PendingAutoTrackEvent(taskID: taskID, occurredAt: Date(timeIntervalSince1970: occurredAt))
            uniqueEvents["\(taskID)|\(Int(occurredAt))"] = event
        }
        return uniqueEvents.values.sorted { $0.occurredAt < $1.occurredAt }
    }
}
