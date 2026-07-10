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
private let authUIDKey = "autoTracking.firebase.uid"
private let authIDTokenKey = "autoTracking.firebase.idToken"
private let authTokenExpirationKey = "autoTracking.firebase.idTokenExpiration"
private let projectIDKey = "autoTracking.firebase.projectID"
private let lastUsageKeyPrefix = "autoTracking.lastUsage."
private let sessionStartKeyPrefix = "autoTracking.sessionStart."
private let thresholdSeconds: TimeInterval = 60
private let inactivityGraceSeconds: TimeInterval = 120

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

        var pendingEvents = sharedDefaults.array(forKey: pendingEventsKey) as? [[String: Any]] ?? []
        pendingEvents.append([
            "taskID": taskID(from: activity),
            "occurredAt": Date().timeIntervalSince1970,
        ])
        sharedDefaults.set(pendingEvents, forKey: pendingEventsKey)

        syncAutoTrackLiveState(taskID: taskID(from: activity), occurredAt: Date(), sharedDefaults: sharedDefaults)
        rearmMonitoring(after: activity)
    }

    private func syncAutoTrackLiveState(taskID: String, occurredAt: Date, sharedDefaults: UserDefaults) {
        guard let uid = sharedDefaults.string(forKey: authUIDKey),
              let idToken = sharedDefaults.string(forKey: authIDTokenKey),
              let projectID = sharedDefaults.string(forKey: projectIDKey) else {
            appendDebugEvent("firebaseSyncSkipped:noAuth", taskID: taskID, occurredAt: occurredAt)
            return
        }

        let expiration = Date(timeIntervalSince1970: sharedDefaults.double(forKey: authTokenExpirationKey))
        guard expiration.timeIntervalSince(occurredAt) > 60 else {
            appendDebugEvent("firebaseSyncSkipped:expiredToken", taskID: taskID, occurredAt: occurredAt)
            return
        }

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

        let liveUntil = occurredAt.addingTimeInterval(inactivityGraceSeconds)
        let updatedAt = Date()
        let urlString = "https://firestore.googleapis.com/v1/projects/\(projectID)/databases/(default)/documents/users/\(uid)/tasks/\(taskID)"
            + "?updateMask.fieldPaths=autoTrackLastUsageAt"
            + "&updateMask.fieldPaths=autoTrackLiveUntil"
            + "&updateMask.fieldPaths=autoTrackSessionStartedAt"
            + "&updateMask.fieldPaths=updatedAt"
        guard let url = URL(string: urlString) else {
            appendDebugEvent("firebaseSyncSkipped:badURL", taskID: taskID, occurredAt: occurredAt)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "fields": [
                "autoTrackLastUsageAt": ["timestampValue": Self.firestoreTimestamp(occurredAt)],
                "autoTrackLiveUntil": ["timestampValue": Self.firestoreTimestamp(liveUntil)],
                "autoTrackSessionStartedAt": ["timestampValue": Self.firestoreTimestamp(sessionStartedAt)],
                "updatedAt": ["timestampValue": Self.firestoreTimestamp(updatedAt)],
            ],
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var statusCode = 0
        var requestError: Error?
        URLSession.shared.dataTask(with: request) { _, response, error in
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            requestError = error
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 8)
        if let requestError {
            appendDebugEvent("firebaseSyncFailed:\(requestError.localizedDescription)", taskID: taskID, occurredAt: occurredAt)
        } else if (200..<300).contains(statusCode) {
            appendDebugEvent("firebaseSynced", taskID: taskID, occurredAt: occurredAt)
        } else {
            appendDebugEvent("firebaseSyncFailed:status\(statusCode)", taskID: taskID, occurredAt: occurredAt)
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

        let generation = Int(Date().timeIntervalSince1970)
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

    private static func firestoreTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter.firestore.string(from: date)
    }
}

private extension ISO8601DateFormatter {
    static let firestore: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
