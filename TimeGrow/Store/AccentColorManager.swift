//
//  AccentColorManager.swift
//  TimeGrow
//

import Combine
import SwiftUI

/// The app's configurable UI accent color (separate from per-task colors), picked from
/// `Settings` and persisted locally. Every screen that used to hard-code `Color.accentPurple`
/// reads this instead, so changing it in Settings updates the whole app.
final class AccentColorManager: ObservableObject {
    static let defaultHex = "#8B5CF6"

    static let presetHexes: [String] = [
        "#8B5CF6", "#7C3AED", "#6366F1", "#3B82F6", "#0EA5E9",
        "#06B6D4", "#14B8A6", "#22C55E", "#84CC16", "#EAB308",
        "#F97316", "#EF4444", "#EC4899", "#D946EF", "#F472B6",
    ]

    private static let storageKey = "app_accent_color_hex"

    @Published var selectedHex: String {
        didSet {
            guard selectedHex != oldValue else { return }
            UserDefaults.standard.set(selectedHex, forKey: Self.storageKey)
        }
    }

    var color: Color {
        TaskAppearance.color(fromHex: selectedHex)
    }

    init() {
        selectedHex = UserDefaults.standard.string(forKey: Self.storageKey) ?? Self.defaultHex
    }
}
