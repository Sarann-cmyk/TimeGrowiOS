//
//  AccountView.swift
//  TimeGrow
//

import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var taskService: TaskService

    var body: some View {
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

            Spacer()
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
