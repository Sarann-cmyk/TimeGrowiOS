//
//  TaskTimeSession.swift
//  TimeGrow
//

import FirebaseFirestore
import Foundation
import SwiftUI

struct TaskTimeSession: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var taskID: String
    var taskName: String
    var colorHex: String
    var startedAt: Date
    var endedAt: Date?
    var startedByDeviceID: String?
    var startedByPlatform: String?
    var startedByDeviceName: String?
    var startedAutomatically: Bool?
    var notes: String?

    var isRunning: Bool { endedAt == nil }

    func duration(at date: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }

    var color: Color {
        TaskAppearance.color(fromHex: colorHex)
    }
}
