//
//  TaskRowView.swift
//  TimeGrow
//

import SwiftUI

struct TaskRow: View {
    let task: TGTask
    let onToggleTimer: () -> Void
    let editAction: () -> Void
    let deleteAction: () -> Void

    @State private var isShowingActionMenu = false

    var body: some View {
        rowContent
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
                Button("Delete", role: .destructive) {
                    Haptics.impact(.rigid)
                    deleteAction()
                }
            }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            TaskAvatarCircle(color: task.color, symbol: task.symbol, isPulsing: task.isTimerRunning)

            Text(task.name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer()

            TaskDurationLabel(task: task)
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(task.isTimerRunning ? task.color.opacity(0.09) : Color.white.opacity(0.07))
        )
        .overlay {
            if task.isTimerRunning {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(task.color.opacity(0.3), lineWidth: 0.7)
            }
        }
    }
}

struct TaskAvatarCircle: View {
    let color: Color
    let symbol: String
    let isPulsing: Bool

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
        Text(symbol.isEmpty ? "T" : symbol)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color))
    }
}

struct TaskDurationLabel: View {
    let task: TGTask

    var body: some View {
        if task.isTimerRunning {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                durationView(seconds: task.totalTrackedSeconds(at: context.date), isRunning: true)
            }
        } else {
            durationView(seconds: task.totalTrackedSeconds(), isRunning: false)
        }
    }

    private func durationView(seconds: TimeInterval, isRunning: Bool) -> some View {
        HStack(spacing: 6) {
            if isRunning {
                Circle()
                    .fill(task.color)
                    .frame(width: 6, height: 6)
            }

            Text(Self.format(seconds))
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(isRunning ? task.color : .secondary)
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}
