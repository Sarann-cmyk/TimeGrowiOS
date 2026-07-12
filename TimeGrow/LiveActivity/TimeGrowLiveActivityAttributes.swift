//
//  TimeGrowLiveActivityAttributes.swift
//  TimeGrow
//

import ActivityKit
import Foundation

struct TimeGrowLiveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
    }

    var taskID: String
    var taskName: String
    var colorHex: String
}
