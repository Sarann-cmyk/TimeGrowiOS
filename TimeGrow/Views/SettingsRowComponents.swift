//
//  SettingsRowComponents.swift
//  TimeGrow
//
//  Shared row/section styling for the Settings tab and its sub-screens
//  (main list, Licensing detail).
//

import SwiftUI

func settingsSectionHeader(_ title: String) -> some View {
    Text(title)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
}

@ViewBuilder
func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) {
        content()
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 4)
    .background {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.07))
    }
}

func settingsIcon(_ systemName: String, color: Color) -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(color)
        .frame(width: 28, height: 28)
        .overlay {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
}

struct SettingsValueRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let showsChevron: Bool
    let showDivider: Bool

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if !value.isEmpty {
                Text(value)
                    .foregroundStyle(.secondary)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showDivider {
                Divider().padding(.leading, 50)
            }
        }
    }
}

struct SettingsMenuRow<Content: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let value: String
    let showDivider: Bool
    @ViewBuilder let menuContent: Content

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            Menu {
                menuContent
            } label: {
                HStack(spacing: 6) {
                    Text(value)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showDivider {
                Divider().padding(.leading, 50)
            }
        }
    }
}

struct SettingsLinkRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let showDivider: Bool
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            trailing()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showDivider {
                Divider().padding(.leading, 50)
            }
        }
    }
}

struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var isOn: Bool
    let showDivider: Bool

    var body: some View {
        HStack(spacing: 12) {
            settingsIcon(icon, color: iconColor)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if showDivider {
                Divider().padding(.leading, 50)
            }
        }
    }
}

/// Placeholder language switch — the app has no localization catalog yet, so this only
/// stores a preference; it doesn't retranslate any UI strings.
enum AppLanguageStub: String, CaseIterable, Identifiable {
    case ukrainian
    case english

    static let storageKey = "settings.languageStub"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ukrainian: return "Українська"
        case .english: return "English"
        }
    }
}
