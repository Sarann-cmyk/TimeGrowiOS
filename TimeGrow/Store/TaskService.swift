//
//  TaskService.swift
//  TimeGrow
//

import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import FirebaseFirestore
import Foundation
import SwiftUI
import UIKit

enum TimerOwnerStatus: Equatable, CustomStringConvertible {
    case notRunning
    case active
    case inactive(deviceName: String?, lastAliveAt: Date?)
    case stale(deviceName: String?, lastAliveAt: Date)
    case unknown

    var description: String {
        switch self {
        case .notRunning: "notRunning"
        case .active: "active"
        case .inactive(let deviceName, let lastAliveAt): "inactive(device=\(deviceName ?? "?"), lastAliveAt=\(lastAliveAt.map(String.init(describing:)) ?? "nil"))"
        case .stale(let deviceName, let lastAliveAt): "stale(device=\(deviceName ?? "?"), lastAliveAt=\(lastAliveAt))"
        case .unknown: "unknown"
        }
    }

    var interruptedAt: Date? {
        switch self {
        case .inactive(_, let lastAliveAt):
            return lastAliveAt
        case .stale(_, let lastAliveAt):
            return lastAliveAt
        case .notRunning, .active, .unknown:
            return nil
        }
    }

    var isInterrupted: Bool {
        switch self {
        case .inactive, .stale:
            return true
        case .notRunning, .active, .unknown:
            return false
        }
    }
}

@MainActor
final class TaskService: NSObject, ObservableObject {
    @Published private(set) var tasks: [TGTask] = [] {
        didSet { LiveActivityManager.shared.reconcile(tasks: tasks) }
    }
    @Published private(set) var sessions: [TaskTimeSession] = []
    @Published private(set) var devices: [String: UserDeviceHeartbeat] = [:]
    @Published private(set) var trackingSettings: TrackingSettings = .defaults
    @Published private(set) var pendingStops: [String: AutoTrackPendingStop] = [:]
    @Published private(set) var isSignedIn = false
    @Published private(set) var currentUser: User?
    @Published var taskDeletionBlockedTaskName: String?

    var isAnonymous: Bool { currentUser?.isAnonymous ?? true }
    var displayName: String? { currentUser?.displayName?.isEmpty == false ? currentUser?.displayName : nil }
    var email: String? { currentUser?.email }

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var sessionsListener: ListenerRegistration?
    private var devicesListener: ListenerRegistration?
    private var trackingSettingsListener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var staleTimer: Timer?
    private var heartbeatTimer: Timer?
    private var currentNonce: String?
    private var autoClosingTaskIDs: Set<String> = []
    private var queuedAutoTrackEvents: [PendingAutoTrackEvent] = []
    private var optimisticTimerStarts: [String: OptimisticTimerStart] = [:]
    private let staleCheckInterval: TimeInterval = 5
    private let heartbeatInterval: TimeInterval = 15
    private let autoTrackingFirebaseProjectID = "timegrowmac"
    private let autoTrackingAuthUIDKey = "autoTracking.firebase.uid"
    private let autoTrackingAuthIDTokenKey = "autoTracking.firebase.idToken"
    private let autoTrackingAuthTokenExpirationKey = "autoTracking.firebase.idTokenExpiration"

    private struct OptimisticTimerStart {
        let sessionID: String?
        let startedAt: Date
        let updatedAt: Date
    }

    private func tasksCollection(for uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("tasks")
    }

    private func sessionsCollection(for uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("sessions")
    }

    private func devicesCollection(for uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("devices")
    }

    private func trackingSettingsDocument(for uid: String) -> DocumentReference {
        db.collection("users").document(uid).collection("settings").document("tracking")
    }

    private func currentDeviceDocument(for uid: String) -> DocumentReference {
        devicesCollection(for: uid).document(Self.currentDeviceID)
    }

    func start() {
        guard authHandle == nil else { return }

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            Task { @MainActor in
                self.currentUser = user
                self.isSignedIn = user != nil
                if let user {
                    self.refreshAutoTrackingFirebaseAuthSnapshot(for: user)
                    self.observeTasks(uid: user.uid)
                    self.observeSessions(uid: user.uid)
                    self.observeDevices(uid: user.uid)
                    self.observeTrackingSettings(uid: user.uid)
                    self.startStaleTimer()
                    self.handleScenePhase(.active)
                } else {
                    self.listener?.remove()
                    self.sessionsListener?.remove()
                    self.devicesListener?.remove()
                    self.trackingSettingsListener?.remove()
                    self.stopStaleTimer()
                    self.stopHeartbeatTimer()
                    self.tasks = []
                    self.sessions = []
                    self.devices = [:]
                    self.pendingStops = [:]
                    self.clearAutoTrackingFirebaseAuthSnapshot()
                }
            }
        }

        if Auth.auth().currentUser == nil {
            Auth.auth().signInAnonymously { _, error in
                if let error {
                    print("Firebase anonymous sign-in failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func refreshAutoTrackingFirebaseAuthSnapshot(for user: User) {
        user.getIDTokenResult(forcingRefresh: false) { [weak self] result, error in
            guard let self else { return }
            if let error {
                print("Failed to refresh auto-tracking Firebase token: \(error.localizedDescription)")
                return
            }
            guard let result,
                  let shared = UserDefaults(suiteName: autoTrackingAppGroupID) else { return }
            shared.set(user.uid, forKey: self.autoTrackingAuthUIDKey)
            shared.set(result.token, forKey: self.autoTrackingAuthIDTokenKey)
            shared.set(result.expirationDate.timeIntervalSince1970, forKey: self.autoTrackingAuthTokenExpirationKey)
            shared.set(self.autoTrackingFirebaseProjectID, forKey: "autoTracking.firebase.projectID")
            print("Updated auto-tracking Firebase auth snapshot. expiresAt=\(result.expirationDate)")
        }
    }

    private func clearAutoTrackingFirebaseAuthSnapshot() {
        guard let shared = UserDefaults(suiteName: autoTrackingAppGroupID) else { return }
        shared.removeObject(forKey: autoTrackingAuthUIDKey)
        shared.removeObject(forKey: autoTrackingAuthIDTokenKey)
        shared.removeObject(forKey: autoTrackingAuthTokenExpirationKey)
        shared.removeObject(forKey: "autoTracking.firebase.projectID")
    }

    private func observeTasks(uid: String) {
        listener?.remove()
        listener = tasksCollection(for: uid)
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    DiagnosticsLog.log("sync", "Firestore tasks listen error: \(error.localizedDescription)")
                    return
                }
                let documents = snapshot?.documents ?? []
                let decoded = documents.compactMap { try? $0.data(as: TGTask.self) }
                Task { @MainActor in
                    let merged = decoded.map { self.mergingOptimisticTimerStart(into: $0) }
                    let runningBeforeIDs = Set(self.tasks.filter(\.isTimerRunning).compactMap(\.id))
                    let runningAfter = merged.filter(\.isTimerRunning)
                    let runningAfterIDs = Set(runningAfter.compactMap(\.id))
                    let stoppedSinceLastSnapshot = self.tasks.filter { runningBeforeIDs.contains($0.id ?? "") && !runningAfterIDs.contains($0.id ?? "") }
                    self.tasks = merged
                    DiagnosticsLog.log("sync", "tasks snapshot count=\(merged.count) running=\(runningAfter.map(\.name))")
                    if !stoppedSinceLastSnapshot.isEmpty {
                        DiagnosticsLog.log("sync", "timer(s) stopped since last snapshot: \(stoppedSinceLastSnapshot.map(\.name))")
                    }
                    self.processQueuedAutoTrackEvents()
                    self.closeRunningAutoTrackedTimers()
                    self.autoCloseInterruptedMacTimers()
                    self.processExpiredPendingStops()
                }
            }
    }

    private func observeSessions(uid: String) {
        sessionsListener?.remove()
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? .distantPast
        sessionsListener = sessionsCollection(for: uid)
            .whereField("startedAt", isGreaterThan: Timestamp(date: cutoff))
            .order(by: "startedAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    DiagnosticsLog.log("sync", "Firestore sessions listen error: \(error.localizedDescription)")
                    return
                }
                let documents = snapshot?.documents ?? []
                let decoded = documents.compactMap { try? $0.data(as: TaskTimeSession.self) }
                Task { @MainActor in
                    self.sessions = decoded
                    self.closeRunningAutoTrackedTimers()
                }
            }
    }

    private func observeDevices(uid: String) {
        devicesListener?.remove()
        devicesListener = devicesCollection(for: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    DiagnosticsLog.log("sync", "Firestore devices listen error: \(error.localizedDescription)")
                    return
                }
                let documents = snapshot?.documents ?? []
                let decoded = documents.compactMap { try? $0.data(as: UserDeviceHeartbeat.self) }
                var devicesByID: [String: UserDeviceHeartbeat] = [:]
                for device in decoded {
                    if let id = device.resolvedDeviceID {
                        devicesByID[id] = device
                    }
                    if let id = device.id {
                        devicesByID[id] = device
                    }
                }
                Task { @MainActor in
                    self.devices = devicesByID
                    let summary = devicesByID.values.map { "\($0.deviceName ?? "?"):\($0.platform ?? "?"):isActive=\($0.isActive ?? false)" }
                    DiagnosticsLog.log("sync", "devices snapshot \(summary)")
                    self.autoCloseInterruptedMacTimers()
                }
            }
    }

    private func observeTrackingSettings(uid: String) {
        trackingSettingsListener?.remove()
        trackingSettingsListener = trackingSettingsDocument(for: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Firestore tracking settings listen error: \(error.localizedDescription)")
                    return
                }

                if let snapshot, snapshot.exists {
                    let settings = (try? snapshot.data(as: TrackingSettings.self)) ?? .defaults
                    Task { @MainActor in
                        self.trackingSettings = settings
                    }
                } else {
                    Task { @MainActor in
                        self.writeTrackingSettings(.defaults, uid: uid)
                    }
                }
            }
    }

    @discardableResult
    func createTask(name: String, color: Color) -> String? {
        guard let uid = currentUser?.uid else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let now = Date()
        let task = TGTask(
            id: nil,
            name: trimmed,
            colorHex: TaskAppearance.hexString(from: color),
            createdAt: now,
            updatedAt: now,
            timerStartedAt: nil,
            activeSessionID: nil,
            timerOwnerDeviceID: nil,
            timerOwnerPlatform: nil,
            timerOwnerDeviceName: nil,
            timerOwnerLastAliveAt: nil,
            timerOwnerIsActive: nil
        )

        do {
            let ref = try tasksCollection(for: uid).addDocument(from: task)
            return ref.documentID
        } catch {
            print("Failed to create task: \(error.localizedDescription)")
            return nil
        }
    }

    func updateTask(_ task: TGTask, name: String, color: Color) {
        guard let uid = currentUser?.uid, let id = task.id else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        tasksCollection(for: uid).document(id).updateData([
            "name": trimmed,
            "colorHex": TaskAppearance.hexString(from: color),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    /// Only deletes the task once it has no tracked sessions left (past or present),
    /// so Reports never ends up with orphaned session entries for a task that no longer exists.
    func deleteTask(_ task: TGTask) {
        guard let uid = currentUser?.uid, let id = task.id else { return }

        Task {
            do {
                let snapshot = try await sessionsCollection(for: uid)
                    .whereField("taskID", isEqualTo: id)
                    .limit(to: 1)
                    .getDocuments()

                guard snapshot.documents.isEmpty else {
                    await MainActor.run {
                        self.taskDeletionBlockedTaskName = task.name
                    }
                    return
                }

                tasksCollection(for: uid).document(id).delete { error in
                    if let error {
                        print("Failed to delete task: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("Failed to check sessions before deleting task: \(error.localizedDescription)")
            }
        }
    }

    func deleteSession(_ session: TaskTimeSession) {
        guard let uid = currentUser?.uid, let sessionID = session.id else { return }

        sessions.removeAll { $0.id == sessionID }
        if let taskIndex = tasks.firstIndex(where: { $0.activeSessionID == sessionID }) {
            tasks[taskIndex].timerStartedAt = nil
            tasks[taskIndex].activeSessionID = nil
            tasks[taskIndex].timerOwnerDeviceID = nil
            tasks[taskIndex].timerOwnerPlatform = nil
            tasks[taskIndex].timerOwnerDeviceName = nil
            tasks[taskIndex].timerOwnerLastAliveAt = nil
            tasks[taskIndex].timerOwnerIsActive = nil
            tasks[taskIndex].updatedAt = Date()
        }

        let taskRef = tasksCollection(for: uid).document(session.taskID)
        sessionsCollection(for: uid).document(sessionID).delete { error in
            if let error {
                print("Failed to delete session: \(error.localizedDescription)")
                return
            }

            guard session.isRunning else { return }
            taskRef.updateData([
                "timerStartedAt": FieldValue.delete(),
                "activeSessionID": FieldValue.delete(),
                "timerOwnerDeviceID": FieldValue.delete(),
                "timerOwnerPlatform": FieldValue.delete(),
                "timerOwnerDeviceName": FieldValue.delete(),
                "timerOwnerLastAliveAt": FieldValue.delete(),
                "timerOwnerIsActive": FieldValue.delete(),
                "updatedAt": Timestamp(date: Date()),
            ])
        }
    }

    /// Edits a past (already-ended) session's time range, task assignment, and notes from the
    /// Reports "Edit Session" screen. Not meant for the currently-running session.
    func updateSession(_ session: TaskTimeSession, startedAt: Date, endedAt: Date, task: TGTask, notes: String?) {
        guard let uid = currentUser?.uid, let sessionID = session.id, let taskID = task.id else { return }

        if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[sessionIndex].startedAt = startedAt
            sessions[sessionIndex].endedAt = endedAt
            sessions[sessionIndex].taskID = taskID
            sessions[sessionIndex].taskName = task.name
            sessions[sessionIndex].colorHex = task.colorHex
            sessions[sessionIndex].notes = notes
        }

        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionsCollection(for: uid).document(sessionID).updateData([
            "startedAt": Timestamp(date: startedAt),
            "endedAt": Timestamp(date: endedAt),
            "taskID": taskID,
            "taskName": task.name,
            "colorHex": task.colorHex,
            "notes": (trimmedNotes?.isEmpty ?? true) ? FieldValue.delete() : trimmedNotes!,
        ])
    }

    func startTimer(for task: TGTask, at startDate: Date = Date(), startedAutomatically: Bool = false) {
        guard let uid = currentUser?.uid,
              let id = task.id,
              !task.isTimerRunning,
              optimisticTimerStarts[id] == nil else {
            DiagnosticsLog.log("timer", "startTimer ignored task=\(task.name) auto=\(startedAutomatically) isRunning=\(task.isTimerRunning)")
            return
        }
        DiagnosticsLog.log("timer", "startTimer task=\(task.name) id=\(id) auto=\(startedAutomatically) at=\(startDate) device=\(Self.currentDeviceName)")
        let now = Date()
        pendingStops.removeValue(forKey: id)
        let sessionRef = sessionsCollection(for: uid).document()

        var session = TaskTimeSession(
            id: nil,
            taskID: id,
            taskName: task.name,
            colorHex: task.colorHex,
            startedAt: startDate,
            endedAt: nil,
            startedByDeviceID: Self.currentDeviceID,
            startedByPlatform: Self.currentPlatform,
            startedByDeviceName: Self.currentDeviceName,
            startedAutomatically: startedAutomatically
        )
        session.id = sessionRef.documentID

        applyOptimisticTimerStart(for: task, session: session, startedAt: startDate, updatedAt: now)

        do {
            try sessionRef.setData(from: session) { error in
                if let error {
                    print("Failed to write session \(sessionRef.documentID): \(error.localizedDescription)")
                } else {
                    print("Wrote session \(sessionRef.documentID) for task \(id)")
                }
            }

            tasksCollection(for: uid).document(id).updateData([
                "timerStartedAt": Timestamp(date: startDate),
                "activeSessionID": sessionRef.documentID,
                "timerOwnerDeviceID": Self.currentDeviceID,
                "timerOwnerPlatform": Self.currentPlatform,
                "timerOwnerDeviceName": Self.currentDeviceName,
                "timerOwnerLastAliveAt": Timestamp(date: now),
                "timerOwnerIsActive": true,
                "updatedAt": Timestamp(date: now),
            ]) { error in
                if let error {
                    DiagnosticsLog.log("timer", "Failed to mark task \(id) running: \(error.localizedDescription)")
                }
            }
        } catch {
            DiagnosticsLog.log("timer", "Failed to start session for task \(id): \(error.localizedDescription)")
        }
    }

    private func applyOptimisticTimerStart(for task: TGTask, session: TaskTimeSession, startedAt: Date, updatedAt: Date) {
        guard let taskID = task.id else { return }
        optimisticTimerStarts[taskID] = OptimisticTimerStart(
            sessionID: session.id,
            startedAt: startedAt,
            updatedAt: updatedAt
        )

        if let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[taskIndex].timerStartedAt = startedAt
            tasks[taskIndex].activeSessionID = session.id
            tasks[taskIndex].timerOwnerDeviceID = Self.currentDeviceID
            tasks[taskIndex].timerOwnerPlatform = Self.currentPlatform
            tasks[taskIndex].timerOwnerDeviceName = Self.currentDeviceName
            tasks[taskIndex].timerOwnerLastAliveAt = updatedAt
            tasks[taskIndex].timerOwnerIsActive = true
            tasks[taskIndex].updatedAt = updatedAt
        }

        if let sessionID = session.id, !sessions.contains(where: { $0.id == sessionID }) {
            sessions.insert(session, at: 0)
        }
    }

    private func mergingOptimisticTimerStart(into task: TGTask) -> TGTask {
        guard let taskID = task.id,
              let optimisticStart = optimisticTimerStarts[taskID] else { return task }

        if task.timerStartedAt != nil {
            optimisticTimerStarts.removeValue(forKey: taskID)
            return task
        }

        var merged = task
        merged.timerStartedAt = optimisticStart.startedAt
        merged.activeSessionID = optimisticStart.sessionID
        merged.timerOwnerDeviceID = Self.currentDeviceID
        merged.timerOwnerPlatform = Self.currentPlatform
        merged.timerOwnerDeviceName = Self.currentDeviceName
        merged.timerOwnerLastAliveAt = optimisticStart.updatedAt
        merged.timerOwnerIsActive = true
        merged.updatedAt = optimisticStart.updatedAt
        return merged
    }

    /// Turns AutoTrackingExtension's queued threshold events into real running
    /// sessions, backdated to when the usage threshold was actually reached.
    func processPendingAutoTrackEvents(_ events: [PendingAutoTrackEvent]) {
        guard !events.isEmpty else { return }
        DiagnosticsLog.log("autoTrack", "queueing \(events.count) pending event(s) tasks=\(events.map(\.taskID)) loadedTasks=\(tasks.count)")
        queuedAutoTrackEvents.append(contentsOf: events)
        processQueuedAutoTrackEvents()
    }

    private func processQueuedAutoTrackEvents() {
        guard !queuedAutoTrackEvents.isEmpty else { return }

        var remainingEvents: [PendingAutoTrackEvent] = []
        for event in queuedAutoTrackEvents {
            guard let task = tasks.first(where: { $0.id == event.taskID }) else {
                DiagnosticsLog.log("autoTrack", "task not loaded yet, re-queuing taskID=\(event.taskID)")
                remainingEvents.append(event)
                continue
            }
            guard !task.isTimerRunning, optimisticTimerStarts[event.taskID] == nil else {
                DiagnosticsLog.log("autoTrack", "skipping event for \(task.name), already running")
                continue
            }
            let endedAt = event.occurredAt
            let startedAt = endedAt.addingTimeInterval(-autoTrackingThresholdSeconds)
            DiagnosticsLog.log("autoTrack", "recording minute for \(task.name) from=\(startedAt) to=\(endedAt) occurredAt=\(event.occurredAt)")
            recordAutoTrackedSession(for: task, startedAt: startedAt, endedAt: endedAt)
        }
        queuedAutoTrackEvents = remainingEvents
    }

    private func recordAutoTrackedSession(for task: TGTask, startedAt: Date, endedAt: Date) {
        guard let uid = currentUser?.uid,
              let taskID = task.id,
              endedAt > startedAt else { return }

        if let existingSession = latestMergeableAutoTrackedSession(for: taskID, nextStartedAt: startedAt),
           let existingSessionID = existingSession.id {
            let mergedEnd = max(existingSession.endedAt ?? existingSession.startedAt, endedAt)
            if let sessionIndex = sessions.firstIndex(where: { $0.id == existingSessionID }) {
                sessions[sessionIndex].endedAt = mergedEnd
            }
            applyOptimisticAutoTrackLiveState(
                taskID: taskID,
                sessionID: existingSessionID,
                sessionStartedAt: existingSession.startedAt,
                lastUsageAt: mergedEnd
            )
            sessionsCollection(for: uid).document(existingSessionID).updateData([
                "endedAt": Timestamp(date: mergedEnd),
            ]) { error in
                if let error {
                    DiagnosticsLog.log("autoTrack", "failed to extend session \(existingSessionID) for \(task.name): \(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("autoTrack", "extended session \(existingSessionID) for \(task.name) to=\(mergedEnd)")
                }
            }
            updateAutoTrackLiveState(
                uid: uid,
                taskID: taskID,
                sessionID: existingSessionID,
                sessionStartedAt: existingSession.startedAt,
                lastUsageAt: mergedEnd
            )
            return
        }

        let sessionRef = sessionsCollection(for: uid).document()
        var session = TaskTimeSession(
            id: nil,
            taskID: taskID,
            taskName: task.name,
            colorHex: task.colorHex,
            startedAt: startedAt,
            endedAt: endedAt,
            startedByDeviceID: Self.currentDeviceID,
            startedByPlatform: Self.currentPlatform,
            startedByDeviceName: Self.currentDeviceName,
            startedAutomatically: true
        )
        session.id = sessionRef.documentID

        if !sessions.contains(where: { $0.id == sessionRef.documentID }) {
            sessions.insert(session, at: 0)
        }
        applyOptimisticAutoTrackLiveState(
            taskID: taskID,
            sessionID: sessionRef.documentID,
            sessionStartedAt: startedAt,
            lastUsageAt: endedAt
        )

        do {
            try sessionRef.setData(from: session) { error in
                if let error {
                    DiagnosticsLog.log("autoTrack", "failed to write session \(sessionRef.documentID) for \(task.name): \(error.localizedDescription)")
                } else {
                    DiagnosticsLog.log("autoTrack", "wrote new session \(sessionRef.documentID) for \(task.name) startedAt=\(startedAt) endedAt=\(endedAt)")
                }
            }
            updateAutoTrackLiveState(
                uid: uid,
                taskID: taskID,
                sessionID: sessionRef.documentID,
                sessionStartedAt: startedAt,
                lastUsageAt: endedAt
            )
        } catch {
            DiagnosticsLog.log("autoTrack", "failed to record session for \(task.name): \(error.localizedDescription)")
        }
    }

    private func applyOptimisticAutoTrackLiveState(taskID: String, sessionID: String, sessionStartedAt: Date, lastUsageAt: Date) {
        guard let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) else { return }
        tasks[taskIndex].autoTrackLastUsageAt = lastUsageAt
        tasks[taskIndex].autoTrackLiveUntil = lastUsageAt.addingTimeInterval(autoTrackingInactivityGraceSeconds)
        tasks[taskIndex].autoTrackActiveSessionID = sessionID
        tasks[taskIndex].autoTrackSessionStartedAt = sessionStartedAt
        tasks[taskIndex].updatedAt = Date()
    }

    private func updateAutoTrackLiveState(uid: String, taskID: String, sessionID: String, sessionStartedAt: Date, lastUsageAt: Date) {
        tasksCollection(for: uid).document(taskID).updateData([
            "autoTrackLastUsageAt": Timestamp(date: lastUsageAt),
            "autoTrackLiveUntil": Timestamp(date: lastUsageAt.addingTimeInterval(autoTrackingInactivityGraceSeconds)),
            "autoTrackActiveSessionID": sessionID,
            "autoTrackSessionStartedAt": Timestamp(date: sessionStartedAt),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    private func latestMergeableAutoTrackedSession(for taskID: String, nextStartedAt: Date) -> TaskTimeSession? {
        sessions
            .filter { session in
                guard session.taskID == taskID,
                      session.startedAutomatically == true,
                      let endedAt = session.endedAt else { return false }
                return nextStartedAt.timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
            }
            .max { first, second in
                (first.endedAt ?? first.startedAt) < (second.endedAt ?? second.startedAt)
            }
    }

    func stopTimer(for task: TGTask) {
        stopTimer(for: task, endedAt: Date(), reason: "manual")
    }

    /// Ends the current auto-tracked "live" grace period early, without touching the already
    /// closed session document. Using the same app again afterward starts a fresh session that
    /// ends later than this cutoff, so tracking resumes naturally — this only silences the
    /// *current* grace window, it can't disable Screen Time monitoring itself.
    func stopAutoTracking(for task: TGTask) {
        guard let uid = currentUser?.uid, let id = task.id else { return }
        let stoppedAt = Date()
        if let taskIndex = tasks.firstIndex(where: { $0.id == id }) {
            tasks[taskIndex].autoTrackStoppedAt = stoppedAt
        }
        tasksCollection(for: uid).document(id).updateData([
            "autoTrackStoppedAt": Timestamp(date: stoppedAt),
            "updatedAt": Timestamp(date: stoppedAt),
        ])
    }

    private func stopTimer(for task: TGTask, endedAt: Date, reason: String = "manual") {
        guard let uid = currentUser?.uid, let id = task.id, let startedAt = task.timerStartedAt else { return }
        DiagnosticsLog.log("timer", "stopTimer task=\(task.name) id=\(id) reason=\(reason) endedAt=\(endedAt) ownerPlatform=\(task.timerOwnerPlatform ?? "?") ownerDevice=\(task.timerOwnerDeviceName ?? "?")")
        pendingStops.removeValue(forKey: id)
        optimisticTimerStarts.removeValue(forKey: id)
        applyOptimisticTimerStop(for: task, endedAt: endedAt)
        tasksCollection(for: uid).document(id).updateData([
            "timerStartedAt": FieldValue.delete(),
            "activeSessionID": FieldValue.delete(),
            "timerOwnerDeviceID": FieldValue.delete(),
            "timerOwnerPlatform": FieldValue.delete(),
            "timerOwnerDeviceName": FieldValue.delete(),
            "timerOwnerLastAliveAt": FieldValue.delete(),
            "timerOwnerIsActive": FieldValue.delete(),
            "updatedAt": Timestamp(date: Date()),
        ])

        if let sessionID = task.activeSessionID {
            if endedAt.timeIntervalSince(startedAt) < minimumTrackedSessionDuration {
                sessions.removeAll { $0.id == sessionID }
                sessionsCollection(for: uid).document(sessionID).delete()
            } else {
                sessionsCollection(for: uid).document(sessionID).updateData([
                    "endedAt": Timestamp(date: endedAt),
                ])
            }
        }
    }

    private func applyOptimisticTimerStop(for task: TGTask, endedAt: Date) {
        guard let taskID = task.id else { return }

        if let taskIndex = tasks.firstIndex(where: { $0.id == taskID }) {
            tasks[taskIndex].timerStartedAt = nil
            tasks[taskIndex].activeSessionID = nil
            tasks[taskIndex].timerOwnerDeviceID = nil
            tasks[taskIndex].timerOwnerPlatform = nil
            tasks[taskIndex].timerOwnerDeviceName = nil
            tasks[taskIndex].timerOwnerLastAliveAt = nil
            tasks[taskIndex].timerOwnerIsActive = nil
            tasks[taskIndex].updatedAt = Date()
        }

        if let activeSessionID = task.activeSessionID,
           let sessionIndex = sessions.firstIndex(where: { $0.id == activeSessionID }) {
            sessions[sessionIndex].endedAt = endedAt
        } else if let sessionIndex = sessions.firstIndex(where: { $0.taskID == taskID && $0.endedAt == nil }) {
            sessions[sessionIndex].endedAt = endedAt
        }
    }

    private func fetchTasks(uid: String) async throws -> [TGTask] {
        let snapshot = try await tasksCollection(for: uid).getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: TGTask.self) }
    }

    /// On-demand fetch for report ranges that may exceed the 30-day `observeSessions` window.
    func fetchSessions(from startDate: Date, to endDate: Date) async throws -> [TaskTimeSession] {
        guard let uid = currentUser?.uid else { return [] }
        let snapshot = try await sessionsCollection(for: uid)
            .whereField("startedAt", isLessThan: Timestamp(date: endDate))
            .order(by: "startedAt", descending: true)
            .getDocuments()
        return snapshot.documents
            .compactMap { try? $0.data(as: TaskTimeSession.self) }
            .filter { ($0.endedAt ?? endDate) > startDate }
    }

    private func importTasks(_ tasksToImport: [TGTask], into uid: String) async {
        for var task in tasksToImport {
            task.id = nil
            do {
                _ = try tasksCollection(for: uid).addDocument(from: task)
            } catch {
                print("Failed to import local task \"\(task.name)\": \(error.localizedDescription)")
            }
        }
        print("Imported \(tasksToImport.count) local task(s) into signed-in account.")
    }

    func updateTrackingSettings(startDelaySeconds: Int? = nil, stopDelaySeconds: Int? = nil) {
        guard let uid = currentUser?.uid else { return }
        var settings = trackingSettings
        if let startDelaySeconds {
            settings.autoTrackStartDelaySeconds = max(0, startDelaySeconds)
        }
        if let stopDelaySeconds {
            settings.autoTrackStopDelaySeconds = max(1, stopDelaySeconds)
        }
        writeTrackingSettings(settings, uid: uid)
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        guard currentUser?.uid != nil else { return }
        switch scenePhase {
        case .active:
            DiagnosticsLog.log("scene", "active runningTasks=\(ownRunningTasks.map(\.name))")
            if let currentUser {
                refreshAutoTrackingFirebaseAuthSnapshot(for: currentUser)
            }
            Task { @MainActor in
                await recoverOwnSuspendedTimers()
                processExpiredPendingStops()
                clearRecoverablePendingStops()
                writeCurrentDeviceHeartbeat(isActive: true)
                startHeartbeatTimer()
            }
        case .background:
            let deactivatedAt = Date()
            DiagnosticsLog.log("scene", "background at=\(deactivatedAt) runningTasks=\(ownRunningTasks.map(\.name))")
            stopHeartbeatTimer()
            writeCurrentDeviceHeartbeat(isActive: false, at: deactivatedAt)
            createPendingStopsForOwnRunningTimers(deactivatedAt: deactivatedAt)
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func writeTrackingSettings(_ settings: TrackingSettings, uid: String) {
        trackingSettingsDocument(for: uid).setData([
            "autoTrackStartDelaySeconds": settings.autoTrackStartDelaySeconds,
            "autoTrackStopDelaySeconds": settings.autoTrackStopDelaySeconds,
            "updatedAt": Timestamp(date: Date()),
        ], merge: true) { error in
            if let error {
                print("Failed to write tracking settings: \(error.localizedDescription)")
            }
        }
    }

    private func startHeartbeatTimer() {
        guard heartbeatTimer == nil else { return }
        writeCurrentDeviceHeartbeat(isActive: true)
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.writeCurrentDeviceHeartbeat(isActive: true)
            }
        }
    }

    private func stopHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    /// Persists this device's ActivityKit push-to-start token so a Cloud Function can start a
    /// Live Activity remotely via APNs even while the app isn't running.
    func updateActivityPushToStartToken(_ token: String) {
        guard let uid = currentUser?.uid else { return }
        currentDeviceDocument(for: uid).setData(["activityPushToStartToken": token], merge: true) { error in
            if let error {
                DiagnosticsLog.log("liveActivity", "Failed to write push-to-start token: \(error.localizedDescription)")
            }
        }
    }

    /// Persists this device's regular APNs device token, used for silent background-wake pushes.
    func updateAPNsDeviceToken(_ token: String) {
        guard let uid = currentUser?.uid else { return }
        currentDeviceDocument(for: uid).setData(["apnsDeviceToken": token], merge: true) { error in
            if let error {
                DiagnosticsLog.log("push", "Failed to write APNs device token: \(error.localizedDescription)")
            }
        }
    }

    /// One-shot fetch of the current tasks (bypassing the live listener), used when the app is
    /// woken in the background by a silent push and needs fresh state before reconciling Live
    /// Activities — the listener may not have reconnected yet in the brief background window.
    func fetchTasksOnce(completion: @escaping ([TGTask]) -> Void) {
        guard let uid = currentUser?.uid else {
            completion([])
            return
        }
        tasksCollection(for: uid).getDocuments { snapshot, error in
            if let error {
                DiagnosticsLog.log("push", "Background fetchTasksOnce failed: \(error.localizedDescription)")
                completion([])
                return
            }
            let tasks = snapshot?.documents.compactMap { try? $0.data(as: TGTask.self) } ?? []
            completion(tasks)
        }
    }

    /// Persists (or clears) the running Live Activity's per-activity push token on its task doc,
    /// so a Cloud Function can push `update`/`end` events via APNs.
    func updateLiveActivityPushToken(taskID: String, token: String?) {
        guard let uid = currentUser?.uid else { return }
        tasksCollection(for: uid).document(taskID).updateData([
            "liveActivityPushToken": token ?? FieldValue.delete(),
        ]) { error in
            if let error {
                DiagnosticsLog.log("liveActivity", "Failed to write activity push token for \(taskID): \(error.localizedDescription)")
            }
        }
    }

    private func writeCurrentDeviceHeartbeat(isActive: Bool, at date: Date = Date()) {
        guard let uid = currentUser?.uid else { return }
        DiagnosticsLog.log("heartbeat", "write isActive=\(isActive) at=\(date) device=\(Self.currentDeviceName)")
        currentDeviceDocument(for: uid).setData([
            "deviceID": Self.currentDeviceID,
            "deviceName": Self.currentDeviceName,
            "platform": Self.currentPlatform,
            "isActive": isActive,
            "lastAliveAt": Timestamp(date: date),
        ], merge: true) { error in
            if let error {
                DiagnosticsLog.log("heartbeat", "write failed: \(error.localizedDescription)")
            }
        }
    }

    /// Only auto-tracked sessions need a "did the app actually die" grace period —
    /// a manually started timer is meant to keep running while the app is backgrounded,
    /// same as any ordinary time tracker. Applying this to manual sessions caused them
    /// to silently stop ~60s after the user locked their phone.
    private func createPendingStopsForOwnRunningTimers(deactivatedAt: Date) {
        let delaySeconds = max(1, trackingSettings.autoTrackStopDelaySeconds)
        let deadline = deactivatedAt.addingTimeInterval(TimeInterval(delaySeconds))
        for task in ownRunningTasks {
            guard let taskID = task.id,
                  activeSession(for: task)?.startedAutomatically == true else { continue }
            DiagnosticsLog.log("pendingStop", "created task=\(task.name) id=\(taskID) deadline=\(deadline) delay=\(delaySeconds)s")
            pendingStops[taskID] = AutoTrackPendingStop(
                deadline: deadline,
                delaySeconds: delaySeconds,
                deactivatedAt: deactivatedAt
            )
        }
    }

    private func clearRecoverablePendingStops() {
        let now = Date()
        for (taskID, pendingStop) in pendingStops {
            if now < pendingStop.deadline {
                pendingStops.removeValue(forKey: taskID)
            }
        }
    }

    private func processExpiredPendingStops() {
        let now = Date()
        for (taskID, pendingStop) in pendingStops where now >= pendingStop.deadline {
            guard let task = tasks.first(where: { $0.id == taskID }) else {
                pendingStops.removeValue(forKey: taskID)
                continue
            }
            stopTimer(for: task, endedAt: pendingStop.deactivatedAt, reason: "pendingStopExpired(delay=\(pendingStop.delaySeconds)s)")
            pendingStops.removeValue(forKey: taskID)
        }
    }

    private func recoverOwnSuspendedTimers() async {
        guard let uid = currentUser?.uid else { return }
        let heartbeatDate: Date?
        do {
            let snapshot = try await currentDeviceDocument(for: uid).getDocument()
            let device = try? snapshot.data(as: UserDeviceHeartbeat.self)
            heartbeatDate = device?.lastAliveAt
        } catch {
            DiagnosticsLog.log("recover", "Failed to fetch heartbeat for recovery: \(error.localizedDescription)")
            heartbeatDate = devices[Self.currentDeviceID]?.lastAliveAt
        }

        guard let deactivatedAt = heartbeatDate else {
            DiagnosticsLog.log("recover", "no heartbeat date found, skipping recovery check")
            return
        }
        let elapsed = Date().timeIntervalSince(deactivatedAt)
        DiagnosticsLog.log("recover", "lastHeartbeat=\(deactivatedAt) elapsed=\(Int(elapsed))s stopDelay=\(trackingSettings.autoTrackStopDelaySeconds)s runningTasks=\(ownRunningTasks.map(\.name))")
        guard elapsed > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) else { return }

        for task in ownRunningTasks {
            guard activeSession(for: task)?.startedAutomatically == true else { continue }
            if let timerStartedAt = task.timerStartedAt, timerStartedAt >= deactivatedAt {
                continue
            }
            stopTimer(for: task, endedAt: deactivatedAt, reason: "recoverOwnSuspendedTimers(elapsed=\(Int(elapsed))s)")
        }
    }

    private var ownRunningTasks: [TGTask] {
        tasks.filter {
            $0.timerStartedAt != nil &&
            ($0.timerOwnerDeviceID == Self.currentDeviceID || $0.timerOwnerDeviceID == nil && $0.timerOwnerPlatform == Self.currentPlatform)
        }
    }

    private func closeRunningAutoTrackedTimers(at endedAt: Date = Date()) {
        for task in ownRunningTasks {
            guard let taskID = task.id,
                  !autoClosingTaskIDs.contains(taskID),
                  let activeSession = activeSession(for: task),
                  activeSession.startedAutomatically == true else { continue }

            autoClosingTaskIDs.insert(taskID)
            stopTimer(for: task, endedAt: endedAt, reason: "closeRunningAutoTrackedTimers")
            autoClosingTaskIDs.remove(taskID)
        }
    }

    private func activeSession(for task: TGTask) -> TaskTimeSession? {
        if let activeSessionID = task.activeSessionID,
           let session = sessions.first(where: { $0.id == activeSessionID }) {
            return session
        }
        guard let taskID = task.id else { return nil }
        return sessions.first { $0.taskID == taskID && $0.endedAt == nil }
    }

    func timerOwnerStatus(for task: TGTask, at date: Date = Date()) -> TimerOwnerStatus {
        guard task.isTimerRunning else { return .notRunning }

        // Manually started timers aren't tied to device/app liveness — they should
        // keep running regardless of heartbeat staleness, same as any ordinary time tracker.
        guard activeSession(for: task)?.startedAutomatically == true else { return .active }

        if task.timerOwnerPlatform?.localizedCaseInsensitiveContains("mac") == true {
            if task.timerOwnerIsActive == false {
                guard let lastAliveAt = task.timerOwnerLastAliveAt else {
                    return .inactive(deviceName: task.timerOwnerDeviceName, lastAliveAt: nil)
                }
                if date.timeIntervalSince(lastAliveAt) > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
                    return .inactive(deviceName: task.timerOwnerDeviceName, lastAliveAt: lastAliveAt)
                }
                return .active
            }
            if let lastAliveAt = task.timerOwnerLastAliveAt,
               date.timeIntervalSince(lastAliveAt) > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
                return .stale(deviceName: task.timerOwnerDeviceName, lastAliveAt: lastAliveAt)
            }
            return .active
        }

        guard let ownerID = task.timerOwnerDeviceID, let device = devices[ownerID] else {
            return .unknown
        }

        let deviceName = device.deviceName ?? task.timerOwnerDeviceName
        if device.isActive == false {
            guard let lastAliveAt = device.lastAliveAt else {
                return .inactive(deviceName: deviceName, lastAliveAt: nil)
            }
            if date.timeIntervalSince(lastAliveAt) > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
                return .inactive(deviceName: deviceName, lastAliveAt: lastAliveAt)
            }
            return .active
        }
        if let lastAliveAt = device.lastAliveAt,
           date.timeIntervalSince(lastAliveAt) > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
            return .stale(deviceName: deviceName, lastAliveAt: lastAliveAt)
        }
        return .active
    }

    private func autoCloseInterruptedMacTimers() {
        guard let uid = currentUser?.uid else { return }

        for task in tasks {
            guard let taskID = task.id,
                  task.timerStartedAt != nil,
                  !autoClosingTaskIDs.contains(taskID) else { continue }

            let status = timerOwnerStatus(for: task)
            guard let interruptedAt = status.interruptedAt else { continue }

            DiagnosticsLog.log(
                "interrupt",
                "REMOTE STOP task=\(task.name) id=\(taskID) status=\(status) ownerPlatform=\(task.timerOwnerPlatform ?? "?") ownerDevice=\(task.timerOwnerDeviceName ?? "?") ownerLastAliveAt=\(task.timerOwnerLastAliveAt.map(String.init(describing:)) ?? "nil") evaluatingDevice=\(Self.currentDeviceName) interruptedAt=\(interruptedAt)"
            )

            autoClosingTaskIDs.insert(taskID)
            closeInterruptedTimer(task, uid: uid, endedAt: interruptedAt)
        }
    }

    private func closeInterruptedTimer(_ task: TGTask, uid: String, endedAt: Date) {
        guard let taskID = task.id else { return }
        pendingStops.removeValue(forKey: taskID)

        let batch = db.batch()
        let taskRef = tasksCollection(for: uid).document(taskID)
        batch.updateData([
            "timerStartedAt": FieldValue.delete(),
            "activeSessionID": FieldValue.delete(),
            "timerOwnerDeviceID": FieldValue.delete(),
            "timerOwnerPlatform": FieldValue.delete(),
            "timerOwnerDeviceName": FieldValue.delete(),
            "timerOwnerLastAliveAt": FieldValue.delete(),
            "timerOwnerIsActive": FieldValue.delete(),
            "updatedAt": Timestamp(date: Date()),
        ], forDocument: taskRef)

        if let sessionID = task.activeSessionID {
            let sessionRef = sessionsCollection(for: uid).document(sessionID)
            if let startedAt = task.timerStartedAt, endedAt.timeIntervalSince(startedAt) < minimumTrackedSessionDuration {
                sessions.removeAll { $0.id == sessionID }
                batch.deleteDocument(sessionRef)
            } else {
                batch.updateData([
                    "endedAt": Timestamp(date: endedAt),
                ], forDocument: sessionRef)
            }
        }

        batch.commit { error in
            Task { @MainActor [weak self] in
                self?.autoClosingTaskIDs.remove(taskID)
                if let error {
                    print("Failed to auto-close interrupted timer: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startStaleTimer() {
        guard staleTimer == nil else { return }
        staleTimer = Timer.scheduledTimer(withTimeInterval: staleCheckInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.processExpiredPendingStops()
                self?.autoCloseInterruptedMacTimers()
            }
        }
    }

    private func stopStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = nil
        autoClosingTaskIDs = []
        pendingStops = [:]
    }

    private static var currentDeviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
    }

    private static var currentDeviceName: String {
        UIDevice.current.name
    }

    private static var currentPlatform: String {
        "iOS"
    }

    // MARK: - Sign in with Apple

    func signInWithApple() {
        let nonce = Self.randomNonceString()
        currentNonce = nonce

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
    }

    func signOut() {
        try? Auth.auth().signOut()
        tasks = []
        Auth.auth().signInAnonymously { _, error in
            if let error {
                print("Firebase anonymous sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    private static func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        precondition(status == errSecSuccess, "Unable to generate nonce: \(status)")

        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }
}

extension TaskService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let idToken = String(data: tokenData, encoding: .utf8) else {
            print("Apple sign-in: missing credential data")
            return
        }
        let fullName = credential.fullName

        Task { @MainActor in
            guard let nonce = currentNonce else { return }
            let firebaseCredential = OAuthProvider.credential(providerID: .apple, idToken: idToken, rawNonce: nonce)

            do {
                let authResult: AuthDataResult
                if let user = Auth.auth().currentUser, user.isAnonymous {
                    do {
                        authResult = try await user.link(with: firebaseCredential)
                        print("Linked anonymous account to Apple ID: \(authResult.user.uid)")
                    } catch {
                        // The credential was already spent on the failed link attempt above —
                        // Firebase hands back a fresh, still-usable credential for this exact
                        // situation via AuthErrorUserInfoUpdatedCredentialKey. Reusing the
                        // original `firebaseCredential` here fails with "Duplicate credential".
                        let nsError = error as NSError
                        guard let updatedCredential = nsError.userInfo[AuthErrorUserInfoUpdatedCredentialKey] as? AuthCredential else {
                            throw error
                        }

                        // This anonymous session's tasks would otherwise be orphaned once we
                        // switch to the pre-existing Apple-linked account, so pull them over first.
                        let orphanedTasks = (try? await self.fetchTasks(uid: user.uid)) ?? []

                        authResult = try await Auth.auth().signIn(with: updatedCredential)
                        print("Signed in to existing Apple-linked account: \(authResult.user.uid)")

                        if !orphanedTasks.isEmpty {
                            await self.importTasks(orphanedTasks, into: authResult.user.uid)
                        }
                    }
                } else {
                    authResult = try await Auth.auth().signIn(with: firebaseCredential)
                    print("Signed in with Apple: \(authResult.user.uid)")
                }

                if authResult.user.displayName?.isEmpty != false, let fullName {
                    let name = PersonNameComponentsFormatter().string(from: fullName)
                    if !name.isEmpty {
                        let changeRequest = authResult.user.createProfileChangeRequest()
                        changeRequest.displayName = name
                        try? await changeRequest.commitChanges()
                    }
                }

                self.currentUser = Auth.auth().currentUser
            } catch {
                print("Apple sign-in failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        print("Apple sign-in error: \(error.localizedDescription)")
    }
}

extension TaskService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }
                .first ?? ASPresentationAnchor()
        }
    }
}
