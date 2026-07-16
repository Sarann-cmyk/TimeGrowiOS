//
//  AppTab.swift
//  TimeGrow
//

import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case tasks
    case timeline
    case reports
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks:
            LanguageManager.localized("Tasks")
        case .timeline:
            LanguageManager.localized("Timeline")
        case .reports:
            LanguageManager.localized("Reports")
        case .settings:
            LanguageManager.localized("Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .tasks:
            "checklist"
        case .timeline:
            "clock.fill"
        case .reports:
            "chart.bar.fill"
        case .settings:
            "gearshape.fill"
        }
    }
}
