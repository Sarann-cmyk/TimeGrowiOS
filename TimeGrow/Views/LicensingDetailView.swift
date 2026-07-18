//
//  LicensingDetailView.swift
//  TimeGrow
//

import SwiftUI

/// No StoreKit product or trial logic exists yet — this screen only offers the
/// account sign-in already used for sync, plus a placeholder activation code field.
struct LicensingDetailView: View {
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @EnvironmentObject private var taskService: TaskService
    @EnvironmentObject private var calendarSyncManager: CalendarSyncManager
    @Environment(\.dismiss) private var dismiss

    @State private var activationCode = ""
    @State private var showActivationAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                topBar

                settingsSectionHeader(LanguageManager.localized("ACCOUNT"))
                AppleAccountCard()

                settingsSectionHeader(LanguageManager.localized("ACTIVATION"))
                settingsGroup {
                    HStack(spacing: 12) {
                        settingsIcon("key.fill", color: .purple)
                        TextField("Activation code", text: $activationCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                        Button("Activate") {
                            Haptics.impact(.light)
                            showActivationAlert = true
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .disabled(activationCode.isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
                }

                Text("Activation isn't wired up yet — this is a placeholder for a future licensing flow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                settingsSectionHeader(LanguageManager.localized("CALENDAR"))
                settingsGroup {
                    SettingsToggleRow(
                        icon: "calendar.badge.clock",
                        iconColor: .red,
                        title: LanguageManager.localized("Sync with Apple Calendar"),
                        isOn: calendarSyncBinding,
                        showDivider: false
                    )
                }
                Text(calendarSyncManager.statusMessage
                     ?? (calendarSyncManager.isEnabled
                         ? LanguageManager.localized("Timeline sessions are mirrored to the separate TimeGrow calendar. Turning this off removes those mirrored events.")
                         : LanguageManager.localized("Turn this on to mirror Timeline sessions to a separate TimeGrow calendar.")))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black.ignoresSafeArea())
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    guard value.startLocation.x < 40,
                          value.translation.width > 80,
                          abs(value.translation.width) > abs(value.translation.height) * 1.5
                    else { return }
                    Haptics.impact(.light)
                    dismiss()
                }
        )
        .alert("Coming soon", isPresented: $showActivationAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("License activation isn't available yet.")
        }
        .preferredColorScheme(.dark)
    }

    private var calendarSyncBinding: Binding<Bool> {
        Binding(
            get: { calendarSyncManager.isEnabled },
            set: { calendarSyncManager.setEnabled($0, taskService: taskService) }
        )
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accentColorManager.color)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.tabBarBackground))
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)

            Text("Licensing")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)

            Spacer()
        }
    }
}

#Preview {
    LicensingDetailView()
        .environmentObject(TaskService())
        .environmentObject(AccentColorManager())
        .environmentObject(CalendarSyncManager.shared)
        .preferredColorScheme(.dark)
}
