//
//  TimeGrowLiveActivityLiveActivity.swift
//  TimeGrowLiveActivity
//
//  Created by Aleks Synelnyk on 12.07.2026.
//

import ActivityKit
import WidgetKit
import SwiftUI
import Foundation

/// Mirrors `TGTask.symbol` (first letter of the task name, uppercased).
private func taskInitial(_ taskName: String) -> String {
    String(taskName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
}

private func liveActivityToggleURL(taskID: String) -> URL {
    var components = URLComponents()
    components.scheme = "timegrow"
    components.host = "toggle-live-activity"
    components.queryItems = [URLQueryItem(name: "taskID", value: taskID)]
    // `taskID` comes from a required Activity attribute, so this URL is always constructible.
    return components.url!
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
                    Link(destination: liveActivityToggleURL(taskID: context.attributes.taskID)) {
                        ExpandedMinuteRing(
                            minuteWindowStart: context.state.minuteWindowStart ?? context.state.startedAt,
                            taskName: context.attributes.taskName,
                            accent: accent
                        )
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerDigitsText(startedAt: context.state.startedAt)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                        // WidgetKit keeps a safe trailing inset in the expanded island. Shift
                        // only the timer into that inset; the leading ring and task title stay put.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .offset(x: 28)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.taskName)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            } compactLeading: {
                // Compact state — show the task avatar next to the camera, with elapsed time on
                // the opposite side. When another app also has an activity, the system switches
                // this widget to `minimal`, which uses the same avatar treatment.
                Link(destination: liveActivityToggleURL(taskID: context.attributes.taskID)) {
                    CompactMinuteRing(
                        minuteWindowStart: context.state.minuteWindowStart ?? context.state.startedAt,
                        taskName: context.attributes.taskName,
                        accent: accent
                    )
                    .offset(x: -1)
                }
            } compactTrailing: {
                // Fixed width keeps iOS from stretching the pill to fit a hypothetical wider
                // value while still leaving room for minutes past one hour.
                TimerDigitsText(startedAt: context.state.startedAt, compact: true)
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                // `Text(timerInterval:)` reserves its own minimum width. Keep that width so
                // WidgetKit doesn't drop the compact trailing view, then move only the rendered
                // digits into the otherwise unused right-side space.
                .frame(width: 60, alignment: .trailing)
                .offset(x: 16)
            } minimal: {
                // Minimal state — shown when two Live Activities are running at once. Digits don't
                // fit here; show the task's initial letter, matching `TaskAvatarCircle` in the app
                // (TaskRowView.swift): outlined circle, no fill, letter in the task's accent color.
                Link(destination: liveActivityToggleURL(taskID: context.attributes.taskID)) {
                    CompactMinuteRing(
                        minuteWindowStart: context.state.minuteWindowStart ?? context.state.startedAt,
                        taskName: context.attributes.taskName,
                        accent: accent
                    )
                }
            }
            .keylineTint(accent)
        }
    }
}

/// Expanded 60-second task-colored ring. The task initial remains readable inside it while the
/// system-driven progress view sweeps around the edge.
private struct ExpandedMinuteRing: View {
    let minuteWindowStart: Date
    let taskName: String
    let accent: Color

    var body: some View {
        let interval = minuteWindowStart...minuteWindowStart.addingTimeInterval(60)
        ZStack {
            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 5)
            ProgressView(
                timerInterval: interval,
                countsDown: false,
                label: { EmptyView() },
                currentValueLabel: { EmptyView() }
            )
            .progressViewStyle(.circular)
            .tint(accent)

            Text(taskInitial(taskName))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: 60, height: 60)
    }
}

/// The compact/minimal Island has room for only one 20pt circle. `ProgressView(timerInterval:)`
/// is deliberately used here instead of a custom trim/TimelineView animation: WidgetKit keeps
/// this system timer progress moving while the app is suspended.
private struct CompactMinuteRing: View {
    let minuteWindowStart: Date
    let taskName: String
    let accent: Color

    var body: some View {
        let interval = minuteWindowStart...minuteWindowStart.addingTimeInterval(60)
        ZStack {
            Circle()
                .stroke(accent.opacity(0.25), lineWidth: 1.4)
            ProgressView(
                timerInterval: interval,
                countsDown: false,
                label: { EmptyView() },
                currentValueLabel: { EmptyView() }
            )
            .progressViewStyle(.circular)
            .tint(accent)
            .scaleEffect(0.88)

            Text(taskInitial(taskName))
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
        }
        .frame(width: 20, height: 20)
    }
}

/// Renders elapsed time as digits only, without the app pushing per-second content updates —
/// `Text(timerInterval:)` is one of the small set of SwiftUI APIs Live Activities animate
/// continuously on the system side.
///
/// Both cases use `showsHours: false` so the display keeps counting minutes past 60 instead of
/// switching to an `H:MM:SS` format (e.g. `61:00`, not `1:01:00`) — `Text(_:style:.timer)` was
/// used previously for `compact: true` but always auto-switches to hours after 60 minutes with
/// no way to opt out, so it can't produce this behavior.
///
/// `Text(timerInterval:)` pre-reserves layout width for the longest string reachable across its
/// *entire* range — a naive 24h range (up to `1439:59`) visibly bloated the compact Dynamic
/// Island pill (confirmed on-device 2026-07-12). Bounding the compact range to ~10 hours
/// (`599:59`, same digit count as anything above 99 minutes) keeps the reserved width modest
/// while still covering any realistic single tracked session.
private struct TimerDigitsText: View {
    let startedAt: Date
    var compact: Bool = false

    var body: some View {
        let rangeEnd = startedAt.addingTimeInterval(compact ? 10 * 60 * 60 : 24 * 60 * 60)
        Text(timerInterval: startedAt...rangeEnd, countsDown: false, showsHours: false)
            .monospacedDigit()
    }
}

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<TimeGrowLiveActivityAttributes>

    private var accent: Color { Color(hex: context.attributes.colorHex) }

    var body: some View {
        HStack(spacing: 12) {
            Link(destination: liveActivityToggleURL(taskID: context.attributes.taskID)) {
                ExpandedMinuteRing(
                    minuteWindowStart: context.state.minuteWindowStart ?? context.state.startedAt,
                    taskName: context.attributes.taskName,
                    accent: accent
                )
                .scaleEffect(0.72)
                .frame(width: 44, height: 44)
            }

            Text(context.attributes.taskName)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TimerDigitsText(startedAt: context.state.startedAt)
                .font(.system(size: 23, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
        }
        // Use nearly all of the system-provided banner width; its outer shape and width remain
        // controlled by iOS, but the content area is about 10% wider than before.
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 15)
        .activityBackgroundTint(accent.opacity(0.10))
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
        TimeGrowLiveActivityAttributes.ContentState(
            startedAt: Date().addingTimeInterval(-125),
            minuteWindowStart: Date().addingTimeInterval(-5)
        )
    }
}

#Preview("Notification", as: .content, using: TimeGrowLiveActivityAttributes.preview) {
   TimeGrowLiveActivityLiveActivity()
} contentStates: {
    TimeGrowLiveActivityAttributes.ContentState.running
}
