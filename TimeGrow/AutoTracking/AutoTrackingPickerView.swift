//
//  AutoTrackingPickerView.swift
//  TimeGrow
//

import FamilyControls
import SwiftUI

struct AutoTrackingPickerView: View {
    let task: TGTask

    @EnvironmentObject private var autoTrackingStore: AutoTrackingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection()
    @State private var isRequestingAuthorization = false

    var body: some View {
        NavigationStack {
            Group {
                if autoTrackingStore.authorizationStatus == .approved {
                    FamilyActivityPicker(selection: $selection)
                } else {
                    permissionPrompt
                }
            }
            .navigationTitle("Автотрекінг")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                }
                if autoTrackingStore.authorizationStatus == .approved {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            if let taskID = task.id {
                                autoTrackingStore.saveSelection(selection, for: taskID)
                            }
                            dismiss()
                        }
                    }
                }
            }
        }
        .onAppear {
            autoTrackingStore.refreshAuthorizationStatus()
            if let taskID = task.id {
                selection = autoTrackingStore.selection(for: taskID)
            }
        }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "hourglass")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Щоб автоматично стартувати «\(task.name)», коли ви відкриваєте вибрані застосунки, дозвольте доступ до Screen Time.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            Button {
                Task {
                    isRequestingAuthorization = true
                    await autoTrackingStore.requestAuthorization()
                    isRequestingAuthorization = false
                }
            } label: {
                if isRequestingAuthorization {
                    ProgressView()
                } else {
                    Text("Надати дозвіл")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRequestingAuthorization)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
