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
    /// True when a delayed DeviceActivity callback proved this duration happened, but iOS did
    /// not provide its exact historical timestamps. Reports still include the confirmed time;
    /// Timeline renders it as an explicitly approximate auto-track credit instead of an exact
    /// "app was open here" interval.
    var hasEstimatedTiming: Bool?
    var notes: String?

    var isRunning: Bool { endedAt == nil }

    var isTimingEstimated: Bool { hasEstimatedTiming == true }

    func duration(at date: Date = Date()) -> TimeInterval {
        max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }

    var color: Color {
        TaskAppearance.color(fromHex: colorHex)
    }
}
