//
//  AppleAccountCard.swift
//  TimeGrow
//

import SwiftUI
import UIKit

struct AppleAccountCard: View {
    @EnvironmentObject private var taskService: TaskService

    @State private var appleLogoTapCount = 0
    @State private var isEmailRevealed = false
    @State private var didCopyEmail = false

    var body: some View {
        if taskService.isAnonymous {
            notSignedInCard
        } else {
            signedInCard
        }
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
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                // Hidden gesture: tapping the logo 7 times reveals the account email below,
                // so it isn't shown by default but is still reachable for support/debugging.
                .contentShape(Circle())
                .onTapGesture {
                    appleLogoTapCount += 1
                    if appleLogoTapCount >= 7 {
                        appleLogoTapCount = 0
                        Haptics.impact(.rigid)
                        withAnimation { isEmailRevealed = true }
                    } else {
                        Haptics.selection()
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(taskService.displayName ?? "Apple Account")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)

                    if isEmailRevealed, let email = taskService.email {
                        Button {
                            UIPasteboard.general.string = email
                            Haptics.impact(.light)
                            didCopyEmail = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                didCopyEmail = false
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(email)
                                Image(systemName: didCopyEmail ? "checkmark" : "doc.on.doc")
                            }
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
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
        .padding(18)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

#Preview {
    AppleAccountCard()
        .environmentObject(TaskService())
        .padding()
        .background(Color.black)
        .preferredColorScheme(.dark)
}
