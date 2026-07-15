//
//  TimeGrowLiveActivityAttributes.swift
//  TimeGrow
//

import ActivityKit
import Foundation

struct TimeGrowLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        /// Beginning of the current 60-second progress window for the expanded ring. Optional
        /// keeps activities started by an older app/server payload decodable.
        var minuteWindowStart: Date?
    }

    var taskID: String
    var taskName: String
    var colorHex: String
}
