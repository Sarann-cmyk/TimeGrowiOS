//
//  TaskRowView.swift
//  TimeGrow
//

import SwiftUI

struct TaskRow: View {
    let task: TGTask
    let sessions: [TaskTimeSession]
    let timerOwnerStatus: (Date) -> TimerOwnerStatus
    let onToggleTimer: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    let autoTrackAction: () -> Void

    @State private var isShowingActionMenu = false

    var body: some View {
        timerAwareRowContent
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.impact(.light)
                onToggleTimer()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    Haptics.impact(.medium)
                    isShowingActionMenu = true
                }
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    Haptics.impact(.rigid)
                    deleteAction()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .confirmationDialog(task.name, isPresented: $isShowingActionMenu, titleVisibility: .visible) {
                Button("Edit") {
                    Haptics.impact(.light)
                    editAction()
                }
                Button("Автотрекінг") {
                    Haptics.impact(.light)
                    autoTrackAction()
                }
                Button("Delete", role: .destructive) {
                    Haptics.impact(.rigid)
                    deleteAction()
                }
            }
    }

    @ViewBuilder
    private var timerAwareRowContent: some View {
        if task.isTimerRunning || isAutoTrackLive(at: Date()) {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: false)) { context in
                rowContent(status: timerOwnerStatus(context.date), date: context.date)
            }
        } else {
            rowContent(status: .notRunning, date: Date())
        }
    }

    private func rowContent(status: TimerOwnerStatus, date: Date) -> some View {
        let autoLiveSession = autoTrackLiveSession(at: date)
        let isAutoLive = autoLiveSession != nil
        let isVisuallyActive = task.isTimerRunning || isAutoLive
        let isInterrupted = task.isTimerRunning && status.isInterrupted
        let secondsStart = task.timerStartedAt ?? autoLiveSession?.startedAt

        return HStack(spacing: 14) {
            TaskProgressStrip(color: isInterrupted ? .orange : task.color)

            TaskAvatarCircle(
                color: task.color,
                symbol: task.symbol,
                isPulsing: isVisuallyActive && !isInterrupted,
                secondsText: isVisuallyActive ? Self.secondsText(startedAt: secondsStart, at: date) : nil
            )

            Text(task.name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            TaskDurationLabel(task: task, sessions: sessions, ownerStatus: status, date: date)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isVisuallyActive ? task.color.opacity(isInterrupted ? 0.05 : 0.09) : Color.white.opacity(0.07))
        )
        .overlay {
            if isVisuallyActive {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isInterrupted ? Color.orange.opacity(0.45) : task.color.opacity(0.3), lineWidth: 0.7)
            }
        }
    }

    private func isAutoTrackLive(at date: Date) -> Bool {
        autoTrackLiveSession(at: date) != nil
    }

    private func autoTrackLiveSession(at date: Date) -> TaskTimeSession? {
        sessions
            .filter { session in
                guard session.startedAutomatically == true,
                      let endedAt = session.endedAt else { return false }
                return date.timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
            }
            .max { first, second in
                (first.endedAt ?? first.startedAt) < (second.endedAt ?? second.startedAt)
            }
    }

    private static func secondsText(startedAt: Date?, at date: Date) -> String {
        guard let startedAt else { return "1" }
        let elapsed = max(0, Int(date.timeIntervalSince(startedAt)))
        return String((elapsed % 60) + 1)
    }
}

private struct TaskProgressStrip: View {
    let color: Color

    private let fullHeight: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 2.4, height: fullHeight)
    }
}

struct TaskAvatarCircle: View {
    let color: Color
    let symbol: String
    let isPulsing: Bool
    var secondsText: String? = nil

    var body: some View {
        if isPulsing {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                let scale = 1.0 + 0.05 * (0.5 + 0.5 * sin(phase * (2 * .pi / 1.6)))
                content.scaleEffect(scale)
            }
        } else {
            content
        }
    }

    private var content: some View {
        Text(secondsText ?? (symbol.isEmpty ? "T" : symbol))
            .font(.system(size: secondsText != nil ? 12 : 15, weight: .bold, design: secondsText != nil ? .monospaced : .default))
            .foregroundStyle(color)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(Color.clear)
                    .overlay {
                        Circle()
                            .stroke(color, lineWidth: 1.2)
                    }
            )
    }
}

struct TaskDurationLabel: View {
    let task: TGTask
    let sessions: [TaskTimeSession]
    let ownerStatus: TimerOwnerStatus
    let date: Date

    private func totalSeconds(at date: Date) -> TimeInterval {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let runningEndDate = ownerStatus.interruptedAt ?? date
        let liveAutoSessionID = autoTrackLiveSession(at: date)?.id

        let sessionSeconds = sessions.reduce(0) { total, session in
            let sessionEnd: Date
            if session.id == liveAutoSessionID {
                sessionEnd = date
            } else {
                sessionEnd = session.endedAt ?? runningEndDate
            }
            let overlapStart = max(session.startedAt, dayStart)
            let overlapEnd = min(sessionEnd, dayEnd)
            return total + max(0, overlapEnd.timeIntervalSince(overlapStart))
        }

        guard task.isTimerRunning,
              let timerStartedAt = task.timerStartedAt,
              !sessions.contains(where: { session in
                  if let activeSessionID = task.activeSessionID, session.id == activeSessionID {
                      return true
                  }
                  return session.endedAt == nil
              }) else {
            return sessionSeconds
        }

        let overlapStart = max(timerStartedAt, dayStart)
        let overlapEnd = min(runningEndDate, dayEnd)
        return sessionSeconds + max(0, overlapEnd.timeIntervalSince(overlapStart))
    }

    var body: some View {
        durationView(
            seconds: totalSeconds(at: date),
            isRunning: (task.isTimerRunning && !ownerStatus.isInterrupted) || autoTrackLiveSession(at: date) != nil
        )
    }

    private func autoTrackLiveSession(at date: Date) -> TaskTimeSession? {
        sessions
            .filter { session in
                guard session.startedAutomatically == true,
                      let endedAt = session.endedAt else { return false }
                return date.timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
            }
            .max { first, second in
                (first.endedAt ?? first.startedAt) < (second.endedAt ?? second.startedAt)
            }
    }

    private func durationView(seconds: TimeInterval, isRunning: Bool) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                Circle()
                    .fill(task.color)
                    .frame(width: 6, height: 6)
            }
            if ownerStatus.isInterrupted {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)
            }

            Text(Self.format(seconds))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(ownerStatus.isInterrupted ? .orange : (isRunning ? task.color : .secondary))
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%02d:%02d", hours, minutes)
    }
}
