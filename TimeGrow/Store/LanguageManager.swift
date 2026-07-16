//
//  LanguageManager.swift
//  TimeGrow
//

import Combine
import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case ukrainian = "uk"

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var displayName: String {
        switch self {
        case .english: "English"
        case .ukrainian: "Українська"
        }
    }
}

/// Overrides the app's SwiftUI locale so switching languages in Settings retranslates every
/// screen immediately, independent of the device's system language.
final class LanguageManager: ObservableObject {
    static let storageKey = "app_language"

    @Published var current: AppLanguage {
        didSet {
            guard current != oldValue else { return }
            UserDefaults.standard.set(current.rawValue, forKey: Self.storageKey)
            let persistedValue = UserDefaults.standard.string(forKey: Self.storageKey) ?? "nil"
            let tasksProbe = Self.localized("Tasks", language: current)
            DiagnosticsLog.log(
                "language",
                "Selection changed old=\(oldValue.rawValue) new=\(current.rawValue) persisted=\(persistedValue) locale=\(current.locale.identifier) Tasks=\(tasksProbe)"
            )
        }
    }

    var locale: Locale {
        current.locale
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.storageKey)
        current = AppLanguage(rawValue: saved ?? "") ?? .english
        DiagnosticsLog.log(
            "language",
            "Manager initialized saved=\(saved ?? "nil") resolved=\(current.rawValue) locale=\(current.locale.identifier) bundleLocalizations=\(Bundle.main.localizations.sorted().joined(separator: ",")) Tasks=\(Self.localized("Tasks", language: current))"
        )
    }

    /// Resolves a catalog key from the language explicitly selected inside the app. On-device,
    /// `String(localized:locale:)` can still prefer the system language for a String Catalog,
    /// so it cannot be used for the app-controlled language switch.
    static func localized(_ key: String) -> String {
        let saved = UserDefaults.standard.string(forKey: storageKey)
        let language = AppLanguage(rawValue: saved ?? "") ?? .english
        return localized(key, language: language)
    }

    private static func localized(_ key: String, language: AppLanguage) -> String {
        guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
}
