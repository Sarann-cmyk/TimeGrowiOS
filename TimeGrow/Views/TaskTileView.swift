//
//  TaskTileView.swift
//  TimeGrow
//

import SwiftUI

/// Compact 2-per-row card shown when the Tasks tab is switched to Tile View.
/// Same interactions as `TaskRow` (tap to toggle, long-press for the action menu) —
/// swipe-to-delete doesn't translate to a grid, so deletion lives in that same menu.
struct TaskTile: View {
    @EnvironmentObject private var autoTrackingStore: AutoTrackingStore

    let task: TGTask
    let sessions: [TaskTimeSession]
    let timerOwnerStatus: (Date) -> TimerOwnerStatus
    let onToggleTimer: () -> Void
    let stopAutoTrackAction: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void
    let autoTrackAction: () -> Void
    var isReorderModeActive: Bool = false

    @State private var isShowingActionMenu = false
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        if isReorderModeActive {
            reorderModeTile
        } else {
            timerAwareTileContent
                .contentShape(Rectangle())
                .onTapGesture {
                    Haptics.impact(.light)
                    if !task.isTimerRunning, isAutoTrackLive(at: Date()) {
                        stopAutoTrackAction()
                    } else {
                        onToggleTimer()
                    }
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        Haptics.impact(.medium)
                        isShowingActionMenu = true
                    }
                )
                .confirmationDialog(task.name, isPresented: $isShowingActionMenu, titleVisibility: .visible) {
                    Button("Edit") {
                        Haptics.impact(.light)
                        editAction()
                    }
                    Button("Auto-tracking") {
                        Haptics.impact(.light)
                        autoTrackAction()
                    }
                    Button("Delete", role: .destructive) {
                        Haptics.impact(.rigid)
                        isShowingDeleteConfirmation = true
                    }
                }
                .alert("Delete “\(task.name)”?", isPresented: $isShowingDeleteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        deleteAction()
                    }
                } message: {
                    Text("This also permanently deletes all its tracked sessions.")
                }
        }
    }

    private var reorderModeTile: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                TaskAvatarCircle(color: task.color, symbol: task.symbol, isPulsing: false, size: 40)

                Spacer(minLength: 8)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(task.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 122)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .reorderJiggle()
    }

    @ViewBuilder
    private var timerAwareTileContent: some View {
        if task.isTimerRunning || isAutoTrackLive(at: Date()) {
            TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: false)) { context in
                tileContent(status: timerOwnerStatus(context.date), date: context.date)
            }
        } else {
            tileContent(status: .notRunning, date: Date())
        }
    }

    private func tileContent(status: TimerOwnerStatus, date: Date) -> some View {
        let autoLiveSession = autoTrackLiveSession(at: date)
        let isAutoLive = autoLiveSession != nil
        let isVisuallyActive = task.isTimerRunning || isAutoLive
        let isInterrupted = task.isTimerRunning && status.isInterrupted
        let secondsStart = task.timerStartedAt ?? autoLiveSession?.startedAt
        let hasAutoTrackingSelection = task.id.map { autoTrackingStore.hasSelection(for: $0) } ?? false

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                TaskAvatarCircle(
                    color: task.color,
                    symbol: task.symbol,
                    isPulsing: isVisuallyActive && !isInterrupted,
                    elapsedSeconds: isVisuallyActive ? TaskRow.elapsedSeconds(startedAt: secondsStart, at: date) : nil,
                    size: 40
                )
                .offset(y: 6)

                Spacer(minLength: 8)

                AutoTrackingBadge(color: task.color, isEnabled: hasAutoTrackingSelection)
            }

            Spacer(minLength: 0)

            HStack(alignment: .lastTextBaseline) {
                Text(task.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Spacer(minLength: 8)

                TaskDurationLabel(task: task, sessions: sessions, ownerStatus: status, date: date)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 122)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isVisuallyActive ? task.color.opacity(isInterrupted ? 0.05 : 0.09) : Color.white.opacity(0.07))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            if isVisuallyActive {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
                if let stoppedAt = task.autoTrackStoppedAt, endedAt <= stoppedAt { return false }
                return date.timeIntervalSince(endedAt) <= autoTrackingInactivityGraceSeconds
            }
            .max { first, second in
                (first.endedAt ?? first.startedAt) < (second.endedAt ?? second.startedAt)
            }
    }
}
