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
            "Tasks"
        case .timeline:
            "Timeline"
        case .reports:
            "Reports"
        case .settings:
            "Settings"
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
