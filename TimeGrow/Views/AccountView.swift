//
//  AccountView.swift
//  TimeGrow
//

import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var taskService: TaskService
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @Environment(\.openURL) private var openURL

    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration
    @AppStorage(AppLanguageStub.storageKey) private var languageStubRawValue = AppLanguageStub.ukrainian.rawValue
    @State private var weekStartSelection = WeekStartSettings.selected

    @State private var logExportItem: IdentifiableURL?
    @State private var didClearLogs = false
    @State private var isShowingAccentColorPicker = false
    @State private var isShowingLicensing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                    settingsSectionHeader("LICENSING")
                    Button {
                        Haptics.impact(.light)
                        isShowingLicensing = true
                    } label: {
                        licensingCard
                    }
                    .buttonStyle(.plain)

                    settingsSectionHeader("GENERAL")
                    settingsGroup {
                        SettingsMenuRow(
                            icon: "globe",
                            iconColor: .blue,
                            title: "Language",
                            value: (AppLanguageStub(rawValue: languageStubRawValue) ?? .ukrainian).displayName,
                            showDivider: true
                        ) {
                            ForEach(AppLanguageStub.allCases) { language in
                                Button(language.displayName) {
                                    languageStubRawValue = language.rawValue
                                }
                            }
                        }

                        Button {
                            Haptics.impact(.light)
                            isShowingAccentColorPicker = true
                        } label: {
                            SettingsLinkRow(
                                icon: "paintpalette.fill",
                                iconColor: accentColorManager.color,
                                title: "Accent Color",
                                showDivider: false
                            ) {
                                Circle()
                                    .fill(accentColorManager.color)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 1)
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSectionHeader("TRACKING")
                    settingsGroup {
                        SettingsMenuRow(
                            icon: "line.3.horizontal.decrease.circle.fill",
                            iconColor: accentColorManager.color,
                            title: "Session List Noise",
                            value: SessionListDisplaySettings.title(for: sessionListMinimumDuration),
                            showDivider: false
                        ) {
                            ForEach(SessionListDisplaySettings.minimumDurationOptions, id: \.self) { seconds in
                                Button {
                                    Haptics.selection()
                                    sessionListMinimumDuration = seconds
                                } label: {
                                    if sessionListMinimumDuration == seconds {
                                        Label(SessionListDisplaySettings.title(for: seconds), systemImage: "checkmark")
                                    } else {
                                        Text(SessionListDisplaySettings.title(for: seconds))
                                    }
                                }
                            }
                        }
                    }
                    Text(SessionListDisplaySettings.description(for: sessionListMinimumDuration))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    settingsSectionHeader("REPORTS")
                    settingsGroup {
                        SettingsMenuRow(
                            icon: "calendar",
                            iconColor: .purple,
                            title: "First Day Of Week",
                            value: weekStartSelection.localizedTitle,
                            showDivider: false
                        ) {
                            ForEach(WeekStartDay.allCases) { day in
                                Button(day.localizedTitle) {
                                    Haptics.selection()
                                    weekStartSelection = day
                                    WeekStartSettings.selected = day
                                }
                            }
                        }
                    }

                    settingsSectionHeader("RESOURCES")
                    settingsGroup {
                        Button {
                            if let url = URL(string: "mailto:support@timegrow.app") {
                                openURL(url)
                            }
                        } label: {
                            SettingsValueRow(icon: "at", iconColor: .blue, title: "Contact Support", value: "", showsChevron: false, showDivider: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let url = URL(string: "https://timegrow.app/privacy") {
                                openURL(url)
                            }
                        } label: {
                            SettingsValueRow(icon: "lock.shield.fill", iconColor: .blue, title: "Privacy Policy", value: "", showsChevron: true, showDivider: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let url = URL(string: "https://apps.apple.com/app/id0000000000?action=write-review") {
                                openURL(url)
                            }
                        } label: {
                            SettingsValueRow(icon: "hand.thumbsup.fill", iconColor: .blue, title: "Rate This App", value: "", showsChevron: true, showDivider: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let url = URL(string: "https://timegrow.app/mac") {
                                openURL(url)
                            }
                        } label: {
                            SettingsValueRow(icon: "waveform.path.ecg", iconColor: .cyan, title: "Get TimeGrow for Mac", value: "", showsChevron: true, showDivider: false)
                        }
                        .buttonStyle(.plain)
                    }

                    settingsSectionHeader("DIAGNOSTICS")
                    Text("Логи запуску/зупинки таймерів (ручний трекінг та автотрекінг) для діагностики проблем із синхронізацією між пристроями.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    settingsGroup {
                        Button {
                            Haptics.impact(.light)
                            if let url = DiagnosticsLog.writeExportFile() {
                                logExportItem = IdentifiableURL(url: url)
                            }
                        } label: {
                            SettingsValueRow(
                                icon: "square.and.arrow.up",
                                iconColor: .blue,
                                title: "Export Logs",
                                value: "",
                                showsChevron: false,
                                showDivider: true
                            )
                        }
                        .buttonStyle(.plain)

                        Button {
                            Haptics.impact(.rigid)
                            DiagnosticsLog.clearAll()
                            didClearLogs = true
                        } label: {
                            SettingsValueRow(
                                icon: "trash.fill",
                                iconColor: .red,
                                title: didClearLogs ? "Logs cleared" : "Clear Logs",
                                value: "",
                                showsChevron: false,
                                showDivider: false
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .sheet(item: $logExportItem) { item in
            ShareSheet(items: [item.url])
        }
        .sheet(isPresented: $isShowingAccentColorPicker) {
            AccentColorPickerSheet()
                .environmentObject(accentColorManager)
        }
        .fullScreenCover(isPresented: $isShowingLicensing) {
            LicensingDetailView()
                .environmentObject(taskService)
                .environmentObject(accentColorManager)
        }
    }

    private var licensingCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.title3)
                .foregroundStyle(Color(red: 0.85, green: 0.35, blue: 0.9))
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("Full license purchased")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(.white)
                Text("Thanks for your support! Your contribution helps us continue improving TimeGrow for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.07))
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(TaskService())
        .environmentObject(AccentColorManager())
        .background(Color.black)
        .preferredColorScheme(.dark)
}
