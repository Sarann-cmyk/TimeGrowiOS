//
//  TimeGrowLiveActivityLiveActivity.swift
//  TimeGrowLiveActivity
//
//  Created by Aleks Synelnyk on 12.07.2026.
//

import ActivityKit
import WidgetKit
import SwiftUI

/// Mirrors `TGTask.symbol` (first letter of the task name, uppercased).
private func taskInitial(_ taskName: String) -> String {
    String(taskName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
}

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
                        .foregroundStyle(.white)
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
                // Fixed width keeps iOS from stretching the pill to fit a hypothetical wider value.
                TimerDigitsText(startedAt: context.state.startedAt, compact: true)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.15)))
                    .frame(width: 52, alignment: .leading)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                // Minimal state — shown when two Live Activities are running at once. Digits don't
                // fit here; show the task's initial letter, matching `TaskAvatarCircle` in the app
                // (TaskRowView.swift): outlined circle, no fill, letter in the task's accent color.
                Text(taskInitial(context.attributes.taskName))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(accent, lineWidth: 1.2))
            }
            .keylineTint(accent)
        }
    }
}

/// Renders elapsed time as digits only, without the app pushing per-second content updates —
/// both styles below are part of the small set of SwiftUI APIs Live Activities animate
/// continuously on the system side.
///
/// `compact: true` uses `Text(_:style:.timer)`, which sizes to its actual current content.
/// `Text(timerInterval:)` (used for `compact: false`) pre-reserves layout width for the longest
/// string reachable across its *entire* range — with a 24h range that's room for a huge minute
/// count even with `showsHours: false` — which visibly bloats the compact Dynamic Island pill
/// (confirmed on-device 2026-07-12: huge gap between `compactLeading`/`compactTrailing`). Keep
/// `Text(timerInterval:)` only where there's headroom to spare (expanded, Lock Screen).
private struct TimerDigitsText: View {
    let startedAt: Date
    var compact: Bool = false

    var body: some View {
        if compact {
            Text(startedAt, style: .timer)
                .monospacedDigit()
        } else {
            Text(timerInterval: startedAt...startedAt.addingTimeInterval(24 * 60 * 60), countsDown: false, showsHours: true)
                .monospacedDigit()
        }
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
                .foregroundStyle(.white)
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
