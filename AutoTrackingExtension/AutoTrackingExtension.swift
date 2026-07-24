//
//  AutoTrackingExtension.swift
//  AutoTrackingExtension
//

import CryptoKit
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
/// Number of 1-minute-apart thresholds armed on a single `startMonitoring` call. Apple fires
/// `eventDidReachThreshold` once per event in the dictionary as cumulative usage crosses each
/// one — steps 1...14 need no restart at all, so only the 15th step pays for a fresh
/// `stopMonitoring`/`startMonitoring` pair. This trades one restart every 15 minutes of
/// continuous usage for one every minute, which is where the ~seconds-per-minute gap from
/// restarting mid-callback came from. Apple warns against registering too many DeviceActivity
/// monitors; 15 is a starting point to validate on-device before pushing higher.
private let accumulatedThresholdStepCount = 15
// Must match `autoTrackingInactivityGraceSeconds` in AutoTrackingStore.swift — same
// "still one session" window, applied here to session-start bookkeeping instead of Firestore
// session merging. See that file for why 300s (DeviceActivity delivery delays observed up to 299s).
private let inactivityGraceSeconds: TimeInterval = 300
private let minimumDistinctThresholdInterval: TimeInterval = 55
/// A threshold that takes noticeably longer than ~60s to fire means that stretch of wall-clock
/// time produced no credited usage — either the app genuinely wasn't used, or iOS delayed/dropped
/// the callback. 90s gives normal delivery jitter room without hiding real gaps.
private let thresholdDelayWarningSeconds: TimeInterval = 90
private let creditedSecondsKeyPrefix = "autoTracking.creditedSecondsToday."
private let unaccountedSecondsKeyPrefix = "autoTracking.unaccountedSecondsToday."
private let countersDayKeyPrefix = "autoTracking.countersDay."

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
        let isFinalStep = accumulatedStep(from: event) == accumulatedThresholdStepCount

        // DeviceActivity may deliver callbacks from a monitor that was already replaced. An old
        // callback must never re-arm over the newer generation.
        let monitoredActivityKey = "\(monitoredActivityKeyPrefix)\(resolvedTaskID)"
        if let currentActivity = sharedDefaults.string(forKey: monitoredActivityKey),
           currentActivity != activity.rawValue {
            appendDebugEvent("eventIgnored:staleActivity", activity: activity)
            return
        }

        let lastQueuedKey = "\(lastQueuedThresholdKeyPrefix)\(resolvedTaskID)"
        let previousQueuedTimestamp = sharedDefaults.object(forKey: lastQueuedKey) as? Double
        if let previousQueuedTimestamp,
           occurredAt.timeIntervalSince(Date(timeIntervalSince1970: previousQueuedTimestamp)) < minimumDistinctThresholdInterval {
            appendDebugEvent("eventIgnored:duplicateThreshold", activity: activity)
            // Steps below the last one are still queued inside this same monitor generation —
            // no restart needed. A duplicate delivery of the final step still means the
            // generation's event dictionary is spent and must be replaced, just without
            // double-crediting usage for it.
            if isFinalStep {
                rearmMonitoring(after: activity)
            }
            return
        }

        recordThresholdAccounting(
            taskID: resolvedTaskID,
            occurredAt: occurredAt,
            previousQueuedTimestamp: previousQueuedTimestamp,
            sharedDefaults: sharedDefaults
        )

        var pendingEvents = sharedDefaults.array(forKey: pendingEventsKey) as? [[String: Any]] ?? []
        pendingEvents.append([
            "taskID": resolvedTaskID,
            "occurredAt": occurredAt.timeIntervalSince1970,
        ])
        sharedDefaults.set(pendingEvents, forKey: pendingEventsKey)
        sharedDefaults.set(occurredAt.timeIntervalSince1970, forKey: lastQueuedKey)

        let sessionStartedAt = resolveSessionStartedAt(taskID: resolvedTaskID, occurredAt: occurredAt, sharedDefaults: sharedDefaults)
        // Steps below the last one are still queued inside this same monitor generation — iOS
        // keeps counting toward them without any restart. Only the final step exhausts the
        // generation's event dictionary and needs a fresh one armed. The pending App Group event
        // is already durable at this point, so when a restart is needed it happens before the
        // network round-trip so the next minute of usage isn't left uncounted behind it.
        if isFinalStep {
            rearmMonitoring(after: activity)
        }
        syncAutoTrackLiveState(taskID: resolvedTaskID, occurredAt: occurredAt, sessionStartedAt: sessionStartedAt, sharedDefaults: sharedDefaults)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter
    }()

    /// Keeps a running daily total of credited usage (exactly `thresholdSeconds` per accepted
    /// threshold — what `TaskService` turns into a session) alongside a running total of
    /// wall-clock time that produced no credit at all. `DiagnosticsLog.exportText()` surfaces
    /// both totals directly so a report of "the numbers don't match Screen Time" doesn't require
    /// manually diffing timestamps across the whole log.
    private func recordThresholdAccounting(
        taskID: String,
        occurredAt: Date,
        previousQueuedTimestamp: Double?,
        sharedDefaults: UserDefaults
    ) {
        let today = Self.dayFormatter.string(from: occurredAt)
        let dayKey = "\(countersDayKeyPrefix)\(taskID)"
        let creditedKey = "\(creditedSecondsKeyPrefix)\(taskID)"
        let unaccountedKey = "\(unaccountedSecondsKeyPrefix)\(taskID)"

        if sharedDefaults.string(forKey: dayKey) != today {
            sharedDefaults.set(0.0, forKey: creditedKey)
            sharedDefaults.set(0.0, forKey: unaccountedKey)
            sharedDefaults.set(today, forKey: dayKey)
        }

        let creditedSeconds = sharedDefaults.double(forKey: creditedKey) + thresholdSeconds
        sharedDefaults.set(creditedSeconds, forKey: creditedKey)

        guard let previousQueuedTimestamp else { return }
        let gap = occurredAt.timeIntervalSince(Date(timeIntervalSince1970: previousQueuedTimestamp))
        guard gap > thresholdDelayWarningSeconds else { return }

        let unaccountedSeconds = sharedDefaults.double(forKey: unaccountedKey) + (gap - thresholdSeconds)
        sharedDefaults.set(unaccountedSeconds, forKey: unaccountedKey)
        appendDebugEvent(
            "thresholdDelay expected=\(Int(thresholdSeconds))s actual=\(Int(gap))s creditedToday=\(Int(creditedSeconds))s unaccountedToday=\(Int(unaccountedSeconds))s",
            taskID: taskID,
            occurredAt: occurredAt
        )
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
        let schedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59),
            repeats: true
        )
        let events = accumulatedThresholdEvents(for: selection, generation: generation)

        do {
            DeviceActivityCenter().stopMonitoring([activity])
            try DeviceActivityCenter().startMonitoring(nextActivity, during: schedule, events: events)
            sharedDefaults.set(nextActivity.rawValue, forKey: "\(monitoredActivityKeyPrefix)\(taskID)")
            // Apple's tokens are opaque — this can never say *which* apps are armed — but the
            // counts and a fingerprint of the raw selection let a later cross-task comparison
            // prove (or rule out) a shared/duplicated selection if two unrelated tasks ever fire
            // together again, instead of only being able to guess.
            let fingerprint = fingerprint(for: selectionData)
            appendDebugEvent(
                "rearmed:\(nextActivity.rawValue) steps=\(events.count) apps=\(selection.applicationTokens.count) categories=\(selection.categoryTokens.count) webDomains=\(selection.webDomainTokens.count) selectionFingerprint=\(fingerprint)",
                activity: activity
            )
        } catch {
            appendDebugEvent("rearmFailed:\(error.localizedDescription)", activity: activity)
        }
    }

    /// Builds the 1...`accumulatedThresholdStepCount` minute-apart event dictionary for one
    /// monitor generation — cumulative thresholds against that generation's own usage counter,
    /// each with a distinct name so `accumulatedStep(from:)` can tell which one fired.
    private func accumulatedThresholdEvents(
        for selection: FamilyActivitySelection,
        generation: String
    ) -> [DeviceActivityEvent.Name: DeviceActivityEvent] {
        var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
        for step in 1...accumulatedThresholdStepCount {
            events[accumulatedEventName(generation: generation, step: step)] = DeviceActivityEvent(
                applications: selection.applicationTokens,
                categories: selection.categoryTokens,
                webDomains: selection.webDomainTokens,
                threshold: DateComponents(minute: step),
                includesPastActivity: false
            )
        }
        return events
    }

    private func accumulatedEventName(generation: String, step: Int) -> DeviceActivityEvent.Name {
        DeviceActivityEvent.Name("thresholdReached|\(generation)|\(step)")
    }

    /// Parses the step number out of an event name built by `accumulatedEventName`. An event
    /// from before this format existed (or any other unrecognized shape) is treated as the final
    /// step — that falls back to the old always-restart behavior rather than silently never
    /// restarting a monitor this code doesn't understand.
    private func accumulatedStep(from event: DeviceActivityEvent.Name) -> Int {
        let parts = event.rawValue.split(separator: "|")
        guard parts.count == 3, let step = Int(parts[2]) else { return accumulatedThresholdStepCount }
        return step
    }

    private func fingerprint(for data: Data) -> String {
        String(SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined().prefix(8))
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
