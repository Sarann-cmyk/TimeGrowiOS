//
//  TaskService.swift
//  TimeGrow
//

import Combine
import FirebaseAuth
import FirebaseFirestore
import Foundation
import SwiftUI

@MainActor
final class TaskService: ObservableObject {
    @Published private(set) var tasks: [TGTask] = []
    @Published private(set) var isSignedIn = false

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?

    private var tasksCollection: CollectionReference {
        db.collection("syncGroups").document(SyncConfiguration.syncCode).collection("tasks")
    }

    func start() {
        if let user = Auth.auth().currentUser {
            print("Firebase already signed in: \(user.uid)")
            isSignedIn = true
            observeTasks()
            return
        }

        Auth.auth().signInAnonymously { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    print("Firebase anonymous sign-in failed: \(error.localizedDescription)")
                    return
                }
                print("Firebase signed in: \(result?.user.uid ?? "-")")
                self.isSignedIn = true
                self.observeTasks()
            }
        }
    }

    private func observeTasks() {
        listener?.remove()
        listener = tasksCollection
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
            let ref = try tasksCollection.addDocument(from: task)
            return ref.documentID
        } catch {
            print("Failed to create task: \(error.localizedDescription)")
            return nil
        }
    }

    func deleteTask(_ task: TGTask) {
        guard let id = task.id else { return }
        tasksCollection.document(id).delete { error in
            if let error {
                print("Failed to delete task: \(error.localizedDescription)")
            }
        }
    }

    func startTimer(for task: TGTask) {
        guard let id = task.id, !task.isTimerRunning else { return }
        tasksCollection.document(id).updateData([
            "timerStartedAt": Timestamp(date: Date()),
            "updatedAt": Timestamp(date: Date()),
        ])
    }

    func stopTimer(for task: TGTask) {
        guard let id = task.id, let startedAt = task.timerStartedAt else { return }
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        tasksCollection.document(id).updateData([
            "timerStartedAt": FieldValue.delete(),
            "trackedSeconds": task.trackedSeconds + elapsed,
            "updatedAt": Timestamp(date: Date()),
        ])
    }
}
