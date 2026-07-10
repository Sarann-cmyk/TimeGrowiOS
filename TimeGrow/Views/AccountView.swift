//
//  AccountView.swift
//  TimeGrow
//

import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var taskService: TaskService

    @AppStorage(SessionListDisplaySettings.minimumDurationKey) private var sessionListMinimumDuration = SessionListDisplaySettings.defaultMinimumDuration
    @State private var logExportItem: IdentifiableURL?
    @State private var didClearLogs = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("APPLE ID")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                if taskService.isAnonymous {
                    notSignedInCard
                } else {
                    signedInCard
                }

                Text("REPORTS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)

                reportsCard

                Text("DIAGNOSTICS")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)

                diagnosticsCard
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $logExportItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var reportsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentPurple)
                    .frame(width: 34, height: 34)
                    .background(Color.accentPurple.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Session list noise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(SessionListDisplaySettings.description(for: sessionListMinimumDuration))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Menu {
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
                } label: {
                    HStack(spacing: 6) {
                        Text(SessionListDisplaySettings.title(for: sessionListMinimumDuration))
                            .font(.system(size: 14, weight: .semibold))
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Логи запуску/зупинки таймерів (ручний трекінг та автотрекінг) для діагностики проблем із синхронізацією між пристроями.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Haptics.impact(.light)
                if let url = DiagnosticsLog.writeExportFile() {
                    logExportItem = IdentifiableURL(url: url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export Logs")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(role: .destructive) {
                Haptics.impact(.rigid)
                DiagnosticsLog.clearAll()
                didClearLogs = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                    Text(didClearLogs ? "Logs cleared" : "Clear Logs")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var notSignedInCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 20))
                    .foregroundStyle(.white)

                Text("Not signed in")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Sign in to sync your tasks across your iPhone and Mac. Without signing in, tasks stay private to this device only.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                taskService.signInWithApple()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo")
                    Text("Sign in with Apple")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var signedInCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: "apple.logo")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(taskService.displayName ?? "Apple Account")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    if let email = taskService.email {
                        Text(email)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 7, height: 7)
                    Text("Synced")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.green)
                }
            }
            .padding(16)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.green.opacity(0.35), lineWidth: 1)
            }

            Text("Your tasks sync across every device signed in with this Apple ID.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                taskService.signOut()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign Out")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(TaskService())
        .background(Color.black)
        .preferredColorScheme(.dark)
}
