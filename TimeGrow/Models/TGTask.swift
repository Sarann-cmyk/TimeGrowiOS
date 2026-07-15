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
    /// Set when the user manually stops an in-progress auto-tracked session. Any auto-tracked
    /// session that ended at or before this moment is no longer treated as "live" during its
    /// grace period — using the same app again afterward starts a fresh session and clears
    /// this naturally, since that new session ends later than this cutoff.
    var autoTrackStoppedAt: Date?
    /// ActivityKit per-activity push token (hex-encoded) for this task's running Live Activity,
    /// letting a server push `update`/`end` events via APNs. Set once the activity starts, cleared
    /// when it ends.
    var liveActivityPushToken: String?
    /// Manual position from the Tasks tab's "Change Order" reorder mode. Tasks without one
    /// yet (never reordered) fall back to `createdAt` ordering.
    var sortOrder: Double? = nil

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
