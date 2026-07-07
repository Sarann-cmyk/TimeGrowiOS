//
//  TGTask.swift
//  TimeGrow
//

import FirebaseFirestore
import Foundation
import SwiftUI

struct TGTask: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var name: String
    var colorHex: String
    var createdAt: Date
    var updatedAt: Date
    var timerStartedAt: Date?
    var activeSessionID: String?
    var timerOwnerDeviceID: String?
    var timerOwnerPlatform: String?
    var timerOwnerDeviceName: String?
    var timerOwnerLastAliveAt: Date?
    var timerOwnerIsActive: Bool?
    var autoTrackLastUsageAt: Date?
    var autoTrackLiveUntil: Date?
    var autoTrackActiveSessionID: String?
    var autoTrackSessionStartedAt: Date?

    static let defaultAccent = Color(red: 0.55, green: 0.84, blue: 0.09)

    var symbol: String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    var color: Color {
        TaskAppearance.color(fromHex: colorHex)
    }

    var isTimerRunning: Bool {
        timerStartedAt != nil
    }
}
