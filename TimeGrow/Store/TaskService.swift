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

enum TimerOwnerStatus: Equatable {
    case notRunning
    case active
    case inactive(deviceName: String?, lastAliveAt: Date?)
    case stale(deviceName: String?, lastAliveAt: Date)
    case unknown

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
    @Published private(set) var tasks: [TGTask] = []
    @Published private(set) var sessions: [TaskTimeSession] = []
    @Published private(set) var devices: [String: UserDeviceHeartbeat] = [:]
    @Published private(set) var trackingSettings: TrackingSettings = .defaults
    @Published private(set) var pendingStops: [String: AutoTrackPendingStop] = [:]
    @Published private(set) var isSignedIn = false
    @Published private(set) var currentUser: User?

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
    private let staleCheckInterval: TimeInterval = 5
    private let heartbeatInterval: TimeInterval = 15

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

    private func observeTasks(uid: String) {
        listener?.remove()
        listener = tasksCollection(for: uid)
            .order(by: "createdAt")
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Firestore listen error: \(error.localizedDescription)")
                    return
                }
                let documents = snapshot?.documents ?? []
                let decoded = documents.compactMap { try? $0.data(as: TGTask.self) }
                Task { @MainActor in
                    self.tasks = decoded
                    print("Firestore tasks updated. count=\(decoded.count)")
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
                    print("Firestore sessions listen error: \(error.localizedDescription)")
                    return
                }
                let documents = snapshot?.documents ?? []
                let decoded = documents.compactMap { try? $0.data(as: TaskTimeSession.self) }
                Task { @MainActor in
                    self.sessions = decoded
                }
            }
    }

    private func observeDevices(uid: String) {
        devicesListener?.remove()
        devicesListener = devicesCollection(for: uid)
            .addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("Firestore devices listen error: \(error.localizedDescription)")
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

    func deleteTask(_ task: TGTask) {
        guard let uid = currentUser?.uid, let id = task.id else { return }
        tasksCollection(for: uid).document(id).delete { error in
            if let error {
                print("Failed to delete task: \(error.localizedDescription)")
            }
        }
    }

    func startTimer(for task: TGTask) {
        guard let uid = currentUser?.uid, let id = task.id, !task.isTimerRunning else { return }
        let now = Date()

        let session = TaskTimeSession(
            id: nil,
            taskID: id,
            taskName: task.name,
            colorHex: task.colorHex,
            startedAt: now,
            endedAt: nil,
            startedByDeviceID: Self.currentDeviceID,
            startedByPlatform: Self.currentPlatform,
            startedByDeviceName: Self.currentDeviceName
        )

        do {
            let ref = try sessionsCollection(for: uid).addDocument(from: session)
            tasksCollection(for: uid).document(id).updateData([
                "timerStartedAt": Timestamp(date: now),
                "activeSessionID": ref.documentID,
                "timerOwnerDeviceID": Self.currentDeviceID,
                "timerOwnerPlatform": Self.currentPlatform,
                "timerOwnerDeviceName": Self.currentDeviceName,
                "timerOwnerLastAliveAt": Timestamp(date: now),
                "timerOwnerIsActive": true,
                "updatedAt": Timestamp(date: now),
            ])
        } catch {
            print("Failed to start session: \(error.localizedDescription)")
        }
    }

    func stopTimer(for task: TGTask) {
        stopTimer(for: task, endedAt: Date())
    }

    private func stopTimer(for task: TGTask, endedAt: Date) {
        guard let uid = currentUser?.uid, let id = task.id, task.timerStartedAt != nil else { return }
        pendingStops.removeValue(forKey: id)
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
            sessionsCollection(for: uid).document(sessionID).updateData([
                "endedAt": Timestamp(date: endedAt),
            ])
        }
    }

    private func fetchTasks(uid: String) async throws -> [TGTask] {
        let snapshot = try await tasksCollection(for: uid).getDocuments()
        return snapshot.documents.compactMap { try? $0.data(as: TGTask.self) }
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
            Task { @MainActor in
                await recoverOwnSuspendedTimers()
                processExpiredPendingStops()
                clearRecoverablePendingStops()
                writeCurrentDeviceHeartbeat(isActive: true)
                startHeartbeatTimer()
            }
        case .background:
            let deactivatedAt = Date()
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

    private func writeCurrentDeviceHeartbeat(isActive: Bool, at date: Date = Date()) {
        guard let uid = currentUser?.uid else { return }
        currentDeviceDocument(for: uid).setData([
            "deviceID": Self.currentDeviceID,
            "deviceName": Self.currentDeviceName,
            "platform": Self.currentPlatform,
            "isActive": isActive,
            "lastAliveAt": Timestamp(date: date),
        ], merge: true) { error in
            if let error {
                print("Failed to write iPhone heartbeat: \(error.localizedDescription)")
            }
        }
    }

    private func createPendingStopsForOwnRunningTimers(deactivatedAt: Date) {
        let delaySeconds = max(1, trackingSettings.autoTrackStopDelaySeconds)
        let deadline = deactivatedAt.addingTimeInterval(TimeInterval(delaySeconds))
        for task in ownRunningTasks {
            guard let taskID = task.id else { continue }
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
            stopTimer(for: task, endedAt: pendingStop.deactivatedAt)
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
            print("Failed to fetch iPhone heartbeat for recovery: \(error.localizedDescription)")
            heartbeatDate = devices[Self.currentDeviceID]?.lastAliveAt
        }

        guard let deactivatedAt = heartbeatDate else { return }
        let elapsed = Date().timeIntervalSince(deactivatedAt)
        guard elapsed > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) else { return }

        for task in ownRunningTasks {
            stopTimer(for: task, endedAt: deactivatedAt)
        }
    }

    private var ownRunningTasks: [TGTask] {
        tasks.filter {
            $0.timerStartedAt != nil &&
            ($0.timerOwnerDeviceID == Self.currentDeviceID || $0.timerOwnerDeviceID == nil && $0.timerOwnerPlatform == Self.currentPlatform)
        }
    }

    func timerOwnerStatus(for task: TGTask, at date: Date = Date()) -> TimerOwnerStatus {
        guard task.isTimerRunning else { return .notRunning }

        if task.timerOwnerPlatform?.localizedCaseInsensitiveContains("mac") == true,
           task.timerOwnerIsActive == false {
            return .inactive(deviceName: task.timerOwnerDeviceName, lastAliveAt: task.timerOwnerLastAliveAt)
        }
        if task.timerOwnerPlatform?.localizedCaseInsensitiveContains("mac") == true,
           let lastAliveAt = task.timerOwnerLastAliveAt,
           date.timeIntervalSince(lastAliveAt) > TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
            return .stale(deviceName: task.timerOwnerDeviceName, lastAliveAt: lastAliveAt)
        }

        guard let ownerID = task.timerOwnerDeviceID, let device = devices[ownerID] else {
            return .unknown
        }

        let deviceName = device.deviceName ?? task.timerOwnerDeviceName
        if device.isActive == false {
            if ownerID == Self.currentDeviceID,
               let lastAliveAt = device.lastAliveAt,
               date.timeIntervalSince(lastAliveAt) <= TimeInterval(trackingSettings.autoTrackStopDelaySeconds) {
                return .active
            }
            return .inactive(deviceName: deviceName, lastAliveAt: device.lastAliveAt)
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
            batch.updateData([
                "endedAt": Timestamp(date: endedAt),
            ], forDocument: sessionRef)
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
