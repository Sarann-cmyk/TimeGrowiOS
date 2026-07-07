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

    var resolvedDeviceID: String? {
        deviceID ?? id
    }
}
