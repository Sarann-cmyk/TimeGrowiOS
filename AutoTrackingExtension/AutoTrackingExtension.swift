//
//  AutoTrackingExtension.swift
//  AutoTrackingExtension
//

import DeviceActivity
import FamilyControls
import Foundation

private let appGroupID = "group.WINNER.ltd.TimeGrow"
private let pendingEventsKey = "autoTracking.pendingEvents"
private let debugEventsKey = "autoTracking.debugEvents"
private let selectionDataKeyPrefix = "autoTracking.selectionData."
private let monitoredActivityKeyPrefix = "autoTracking.monitoredActivity."
private let lastQueuedThresholdKeyPrefix = "autoTracking.lastQueuedThreshold."
private let authUIDKey = "autoTracking.firebase.uid"
private let projectIDKey = "autoTracking.firebase.projectID"
private let deviceIDKey = "autoTracking.deviceID"
private let deviceSecretKey = "autoTracking.deviceSecret"
private let lastUsageKeyPrefix = "autoTracking.lastUsage."
private let sessionStartKeyPrefix = "autoTracking.sessionStart."
private let thresholdSeconds: TimeInterval = 60
private let inactivityGraceSeconds: TimeInterval = 180
private let minimumDistinctThresholdInterval: TimeInterval = 55

final class DeviceActivityMonitorExtension: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        appendDebugEvent("intervalDidStart", activity: activity)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        appendDebugEvent("intervalDidEnd", activity: activity)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        appendDebugEvent("eventDidReachThreshold:\(event.rawValue)", activity: activity)

        guard let sharedDefaults = UserDefaults(suiteName: appGroupID) else { return }

        let resolvedTaskID = taskID(from: activity)
        let occurredAt = Date()

        // DeviceActivity may deliver callbacks from a monitor that was already replaced. An old
        // callback must never re-arm over the newer generation.
        let monitoredActivityKey = "\(monitoredActivityKeyPrefix)\(resolvedTaskID)"
        if let currentActivity = sharedDefaults.string(forKey: monitoredActivityKey),
           currentActivity != activity.rawValue {
            appendDebugEvent("eventIgnored:staleActivity", activity: activity)
            return
        }

        let lastQueuedKey = "\(lastQueuedThresholdKeyPrefix)\(resolvedTaskID)"
        if let previousTimestamp = sharedDefaults.object(forKey: lastQueuedKey) as? Double,
           occurredAt.timeIntervalSince(Date(timeIntervalSince1970: previousTimestamp)) < minimumDistinctThresholdInterval {
            appendDebugEvent("eventIgnored:duplicateThreshold", activity: activity)
            rearmMonitoring(after: activity)
            return
        }

        var pendingEvents = sharedDefaults.array(forKey: pendingEventsKey) as? [[String: Any]] ?? []
        pendingEvents.append([
            "taskID": resolvedTaskID,
            "occurredAt": occurredAt.timeIntervalSince1970,
        ])
        sharedDefaults.set(pendingEvents, forKey: pendingEventsKey)
        sharedDefaults.set(occurredAt.timeIntervalSince1970, forKey: lastQueuedKey)

        let sessionStartedAt = resolveSessionStartedAt(taskID: resolvedTaskID, occurredAt: occurredAt, sharedDefaults: sharedDefaults)
        syncAutoTrackLiveState(taskID: resolvedTaskID, occurredAt: occurredAt, sessionStartedAt: sessionStartedAt, sharedDefaults: sharedDefaults)
        rearmMonitoring(after: activity)
    }

    /// Reuses (if within the inactivity grace period) or starts a new session-start timestamp,
    /// persisting it so both the Live Activity and the Firestore sync below agree on it.
    private func resolveSessionStartedAt(taskID: String, occurredAt: Date, sharedDefaults: UserDefaults) -> Date {
        let lastUsageKey = "\(lastUsageKeyPrefix)\(taskID)"
        let sessionStartKey = "\(sessionStartKeyPrefix)\(taskID)"
        let previousLastUsage = Date(timeIntervalSince1970: sharedDefaults.double(forKey: lastUsageKey))
        let canResume = sharedDefaults.object(forKey: lastUsageKey) != nil
            && occurredAt.timeIntervalSince(previousLastUsage) <= inactivityGraceSeconds

        let sessionStartedAt: Date
        if canResume, sharedDefaults.object(forKey: sessionStartKey) != nil {
            sessionStartedAt = Date(timeIntervalSince1970: sharedDefaults.double(forKey: sessionStartKey))
        } else {
            sessionStartedAt = occurredAt.addingTimeInterval(-thresholdSeconds)
        }

        sharedDefaults.set(occurredAt.timeIntervalSince1970, forKey: lastUsageKey)
        sharedDefaults.set(sessionStartedAt.timeIntervalSince1970, forKey: sessionStartKey)
        return sessionStartedAt
    }

    /// Sends an auto-track event to the server with a long-lived per-device secret. Unlike the
    /// Firebase ID-token snapshot used before, this remains valid after the main app has been
    /// closed overnight; the function writes Firestore and the existing push-to-start trigger
    /// creates the Live Activity.
    private func syncAutoTrackLiveState(taskID: String, occurredAt: Date, sessionStartedAt: Date, sharedDefaults: UserDefaults) {
        submitAutoTrackEvent(
            taskID: taskID,
            occurredAt: occurredAt,
            sessionStartedAt: sessionStartedAt,
            sharedDefaults: sharedDefaults
        )
    }

    private func submitAutoTrackEvent(
        taskID: String,
        occurredAt: Date,
        sessionStartedAt: Date,
        sharedDefaults: UserDefaults
    ) {
        guard let uid = sharedDefaults.string(forKey: authUIDKey),
              let projectID = sharedDefaults.string(forKey: projectIDKey),
              let deviceID = sharedDefaults.string(forKey: deviceIDKey),
              let deviceSecret = sharedDefaults.string(forKey: deviceSecretKey),
              !deviceID.isEmpty,
              !deviceSecret.isEmpty else {
            appendDebugEvent("secureSyncSkipped:noDeviceCredential", taskID: taskID, occurredAt: occurredAt)
            return
        }

        let urlString = "https://us-central1-\(projectID).cloudfunctions.net/recordAutoTrackEvent"
        guard let url = URL(string: urlString) else {
            appendDebugEvent("secureSyncSkipped:badURL", taskID: taskID, occurredAt: occurredAt)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "uid": uid,
            "deviceID": deviceID,
            "deviceSecret": deviceSecret,
            "taskID": taskID,
            "occurredAt": occurredAt.timeIntervalSince1970,
            "sessionStartedAt": sessionStartedAt.timeIntervalSince1970,
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = 0
        var requestError: Error?
        URLSession.shared.dataTask(with: request) { _, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            requestError = error
            semaphore.signal()
        }.resume()

        // The pending App Group event is durable. Do not monopolize the extension for eight
        // seconds while an unreliable network is attempting the faster server-side path.
        _ = semaphore.wait(timeout: .now() + 3)
        if let requestError {
            appendDebugEvent("secureSyncFailed:\(requestError.localizedDescription)", taskID: taskID, occurredAt: occurredAt)
        } else if (200..<300).contains(statusCode) {
            appendDebugEvent("secureEndpointSynced", taskID: taskID, occurredAt: occurredAt)
        } else {
            appendDebugEvent("secureSyncFailed:status\(statusCode)", taskID: taskID, occurredAt: occurredAt)
        }
    }

    private func rearmMonitoring(after activity: DeviceActivityName) {
        let taskID = taskID(from: activity)
        guard let sharedDefaults = UserDefaults(suiteName: appGroupID),
              let selectionData = sharedDefaults.data(forKey: "\(selectionDataKeyPrefix)\(taskID)"),
              let selection = try? JSONDecoder().decode(FamilyActivitySelection.self, from: selectionData),
              !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty || !selection.webDomainTokens.isEmpty else {
            appendDebugEvent("rearmSkipped", activity: activity)
            return
        }

        // A second-resolution generation collides during rapid callback delivery and can make a
        // monitor re-arm itself. Use an unambiguously new generation instead.
        let generation = UUID().uuidString
        let nextActivity = DeviceActivityName("\(taskID)|\(generation)")
        let nextEventName = DeviceActivityEvent.Name("thresholdReached|\(generation)")
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
            DeviceActivityCenter().stopMonitoring([activity])
            try DeviceActivityCenter().startMonitoring(nextActivity, during: schedule, events: [nextEventName: event])
            sharedDefaults.set(nextActivity.rawValue, forKey: "\(monitoredActivityKeyPrefix)\(taskID)")
            appendDebugEvent("rearmed:\(nextActivity.rawValue)", activity: activity)
        } catch {
            appendDebugEvent("rearmFailed:\(error.localizedDescription)", activity: activity)
        }
    }

    private func appendDebugEvent(_ name: String, activity: DeviceActivityName) {
        appendDebugEvent(name, taskID: taskID(from: activity), activity: activity.rawValue, occurredAt: Date())
    }

    private func appendDebugEvent(_ name: String, taskID: String, occurredAt: Date) {
        appendDebugEvent(name, taskID: taskID, activity: taskID, occurredAt: occurredAt)
    }

    private func appendDebugEvent(_ name: String, taskID: String, activity: String, occurredAt: Date) {
        guard let sharedDefaults = UserDefaults(suiteName: appGroupID) else { return }
        var debugEvents = sharedDefaults.array(forKey: debugEventsKey) as? [[String: Any]] ?? []
        debugEvents.append([
            "name": name,
            "activity": activity,
            "taskID": taskID,
            "occurredAt": occurredAt.timeIntervalSince1970,
        ])
        sharedDefaults.set(Array(debugEvents.suffix(300)), forKey: debugEventsKey)
    }

    private func taskID(from activity: DeviceActivityName) -> String {
        activity.rawValue.split(separator: "|", maxSplits: 1).first.map(String.init) ?? activity.rawValue
    }

}
