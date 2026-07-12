//
//  TimeGrowLiveActivityLiveActivity.swift
//  TimeGrowLiveActivity
//
//  Created by Aleks Synelnyk on 12.07.2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct TimeGrowLiveActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TimeGrowLiveActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
        } dynamicIsland: { context in
            let accent = Color(hex: context.attributes.colorHex)

            return DynamicIsland {
                // Expanded state — shown when the user long-presses the island.
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.attributes.taskName)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerDigitsText(startedAt: context.state.startedAt)
                        .font(.system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Capsule()
                        .fill(accent)
                        .frame(height: 3)
                }
            } compactLeading: {
                // Compact state — single active Live Activity, oval pill next to the camera.
                Image(systemName: "timer")
                    .foregroundStyle(accent)
            } compactTrailing: {
                TimerDigitsText(startedAt: context.state.startedAt)
                    .foregroundStyle(accent)
                    .frame(width: 50)
            } minimal: {
                // Minimal state — shown when two Live Activities are running at once.
                Image(systemName: "timer")
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

/// Renders elapsed time as digits only. Uses `Text(timerInterval:)` per Apple's guidance so the
/// system updates the display every second without the app pushing per-second content updates.
private struct TimerDigitsText: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...startedAt.addingTimeInterval(24 * 60 * 60), countsDown: false, showsHours: true)
            .monospacedDigit()
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TimeGrowLiveActivityAttributes>

    private var accent: Color { Color(hex: context.attributes.colorHex) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent)
                .frame(width: 10, height: 10)
            Text(context.attributes.taskName)
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
            Spacer()
            TimerDigitsText(startedAt: context.state.startedAt)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(accent)
        }
        .padding()
        .activityBackgroundTint(Color.black)
        .activitySystemActionForegroundColor(Color.white)
    }
}

private extension Color {
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard sanitized.count == 6, let value = UInt32(sanitized, radix: 16) else {
            self = .green
            return
        }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

extension TimeGrowLiveActivityAttributes {
    fileprivate static var preview: TimeGrowLiveActivityAttributes {
        TimeGrowLiveActivityAttributes(taskID: "preview", taskName: "Preview Task", colorHex: "#8CD616")
    }
}

extension TimeGrowLiveActivityAttributes.ContentState {
    fileprivate static var running: TimeGrowLiveActivityAttributes.ContentState {
        TimeGrowLiveActivityAttributes.ContentState(startedAt: Date().addingTimeInterval(-125))
    }
}

#Preview("Notification", as: .content, using: TimeGrowLiveActivityAttributes.preview) {
   TimeGrowLiveActivityLiveActivity()
} contentStates: {
    TimeGrowLiveActivityAttributes.ContentState.running
}
