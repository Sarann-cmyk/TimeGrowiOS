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

@MainActor
final class TaskService: NSObject, ObservableObject {
    @Published private(set) var tasks: [TGTask] = []
    @Published private(set) var isSignedIn = false
    @Published private(set) var currentUser: User?

    var isAnonymous: Bool { currentUser?.isAnonymous ?? true }
    var displayName: String? { currentUser?.displayName?.isEmpty == false ? currentUser?.displayName : nil }
    var email: String? { currentUser?.email }

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var currentNonce: String?

    private func tasksCollection(for uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("tasks")
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
                } else {
                    self.listener?.remove()
                    self.tasks = []
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
            trackedSeconds: 0,
            timerStartedAt: nil
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
        tasksCollection(for: uid).document(id).updateData([
            "timerStartedAt": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    func stopTimer(for task: TGTask) {
        guard let uid = currentUser?.uid, let id = task.id, let startedAt = task.timerStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        tasksCollection(for: uid).document(id).updateData([
            "timerStartedAt": FieldValue.delete(),
            "trackedSeconds": task.trackedSeconds + elapsed,
            "updatedAt": Timestamp(date: Date()),
        ])
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
