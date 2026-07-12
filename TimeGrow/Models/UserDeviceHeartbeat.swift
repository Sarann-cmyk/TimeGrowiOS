//
//  UserDeviceHeartbeat.swift
//  TimeGrow
//

import FirebaseFirestore
import Foundation

struct UserDeviceHeartbeat: Identifiable, Codable, Equatable {
    @DocumentID var id: String?
    var deviceID: String?
    var deviceName: String?
    var platform: String?
    var isActive: Bool?
    var lastAliveAt: Date?
    /// ActivityKit push-to-start token (hex-encoded) for this device, letting a server start a
    /// new `TimeGrowLiveActivityAttributes` Live Activity via APNs even while the app isn't running.
    var activityPushToStartToken: String?
    /// Regular APNs device token (hex-encoded) for silent background wake pushes. Push-to-start
    /// alone proved unreliable on-device (system acknowledges it but doesn't always materialize
    /// the activity); a `content-available` push wakes the app so it can call the already-proven
    /// local `LiveActivityManager.reconcile()` path instead.
    var apnsDeviceToken: String?

    var resolvedDeviceID: String? {
        deviceID ?? id
    }
}
