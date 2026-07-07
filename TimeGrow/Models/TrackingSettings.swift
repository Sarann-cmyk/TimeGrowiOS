//
//  TrackingSettings.swift
//  TimeGrow
//

import FirebaseFirestore
import Foundation

struct TrackingSettings: Codable, Equatable {
    var autoTrackStartDelaySeconds: Int
    var autoTrackStopDelaySeconds: Int
    var updatedAt: Date?

    static let defaults = TrackingSettings(
        autoTrackStartDelaySeconds: 30,
        autoTrackStopDelaySeconds: 90,
        updatedAt: nil
    )
}

struct AutoTrackPendingStop: Equatable {
    let deadline: Date
    let delaySeconds: Int
    let deactivatedAt: Date
}
