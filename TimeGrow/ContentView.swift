//
//  ContentView.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI
import UIKit

private enum Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct ContentView: View {
    @EnvironmentObject private var taskService: TaskService

    @State private var selectedTab: AppTab = .tasks
    @State private var isShowingAddTask = false
    @State private var taskBeingEdited: TGTask?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                Group {
                    switch selectedTab {
                    case .tasks:
                        tasksView
                    case .timeline:
                        placeholderView("Timeline")
                    case .reports:
                        placeholderView("Reports")
                    case .settings:
                        AccountView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            tabBar
        }
        .sheet(isPresented: $isShowingAddTask) {
            TaskFormView(navigationTitle: "New Task", confirmTitle: "Create") { name, color in
                taskService.createTask(name: name, color: color)
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $taskBeingEdited) { task in
            TaskFormView(
                initialName: task.name,
                initialColor: task.color,
                navigationTitle: "Edit Task",
                confirmTitle: "Save"
            ) { name, color in
                taskService.updateTask(task, name: name, color: color)
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(selectedTab.title)
                .font(.system(size: 38, weight: .bold, design: .default))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.75)

            Spacer()

            if selectedTab == .tasks {
                Button {
                    Haptics.impact(.light)
                    isShowingAddTask = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 25, weight: .semibold))
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add task")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 0)
        .frame(height: 65, alignment: .bottom)
    }

    private var tasksView: some View {
        Group {
            if taskService.tasks.isEmpty {
                Text("No tasks yet")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 76)
            } else {
                List {
                    ForEach(taskService.tasks) { task in
                        TaskRow(
                            task: task,
                            onToggleTimer: { toggleTimer(task) },
                            editAction: { taskBeingEdited = task },
                            deleteAction: { taskService.deleteTask(task) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 21, bottom: 6, trailing: 21))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .contentMargins(.top, 26, for: .scrollContent)
                .contentMargins(.bottom, 112, for: .scrollContent)
            }
        }
    }

    private func toggleTimer(_ task: TGTask) {
        if task.isTimerRunning {
            taskService.stopTimer(for: task)
        } else {
            taskService.startTimer(for: task)
        }
    }

    private func placeholderView(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 27, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 76)
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    if selectedTab != tab {
                        Haptics.selection()
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: tab == .tasks ? 20 : 23, weight: .bold))
                            .symbolRenderingMode(.hierarchical)

                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.accentPurple : .white)
                    .frame(maxWidth: .infinity, minHeight: 62)
                    .background {
                        if selectedTab == tab {
                            Capsule()
                                .fill(Color.selectedTabBackground)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 4)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(4)
        .frame(height: 70)
        .background {
            Capsule()
                .fill(Color.tabBarBackground)
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.11), lineWidth: 1)
                }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 0)
        .offset(y: 10)
    }
}

private struct TaskRow: View {
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
                    .stroke(task.color.opacity(0.3), lineWidth: 1)
            }
        }
    }
}

private struct TaskAvatarCircle: View {
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
            .foregroundStyle(.black.opacity(0.8))
            .frame(width: 34, height: 34)
            .background {
                Circle()
                    .fill(color)
                    .overlay {
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), .clear, Color.black.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(Circle())
                    }
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    }
            }
    }
}

private struct TaskDurationLabel: View {
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

private struct TaskFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var taskName: String
    @State private var customColors: [Color]
    @State private var selectedColorIndex: Int
    @State private var isShowingCustomColorPicker = false

    let navigationTitle: String
    let confirmTitle: String
    let onSave: (String, Color) -> Void

    private static let colors: [Color] = [
        // Row 1
        Color(red: 0.61, green: 0.24, blue: 0.78), // purple
        Color(red: 0.85, green: 0.12, blue: 0.47), // magenta / raspberry
        Color(red: 0.88, green: 0.14, blue: 0.24), // red
        Color(red: 0.97, green: 0.58, blue: 0.12), // orange
        Color(red: 1.00, green: 0.80, blue: 0.00), // yellow
        Color(red: 0.20, green: 0.78, blue: 0.35), // green
        Color(red: 0.35, green: 0.78, blue: 0.98), // sky blue
        Color(red: 0.00, green: 0.48, blue: 1.00), // blue
        // Row 2
        Color(red: 0.35, green: 0.34, blue: 0.84), // indigo
        Color(red: 0.69, green: 0.51, blue: 0.92), // lavender
        Color(red: 1.00, green: 0.41, blue: 0.71), // pink
        Color(red: 1.00, green: 0.44, blue: 0.38), // coral
        Color(red: 0.64, green: 0.46, blue: 0.30), // brown
        Color(red: 0.18, green: 0.80, blue: 0.60), // mint
        Color(red: 0.19, green: 0.69, blue: 0.78), // teal
    ]

    init(
        initialName: String = "",
        initialColor: Color = TGTask.defaultAccent,
        navigationTitle: String,
        confirmTitle: String,
        onSave: @escaping (String, Color) -> Void
    ) {
        _taskName = State(initialValue: initialName)
        let initialHex = TaskAppearance.hexString(from: initialColor)
        if let matchedIndex = Self.colors.firstIndex(where: { TaskAppearance.hexString(from: $0) == initialHex }) {
            _selectedColorIndex = State(initialValue: matchedIndex)
            _customColors = State(initialValue: [])
        } else {
            _selectedColorIndex = State(initialValue: Self.colors.count)
            _customColors = State(initialValue: [initialColor])
        }
        self.navigationTitle = navigationTitle
        self.confirmTitle = confirmTitle
        self.onSave = onSave
    }

    private var allColors: [Color] { Self.colors + customColors }

    private var selectedColor: Color { allColors[selectedColorIndex] }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Task name", text: $taskName)
                    .font(.system(size: 18, weight: .medium))
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 12)], spacing: 12) {
                        ForEach(Self.colors.indices, id: \.self) { index in
                            colorSwatch(color: Self.colors[index], isSelected: selectedColorIndex == index) {
                                selectedColorIndex = index
                            }
                        }

                        Button {
                            Haptics.impact(.light)
                            isShowingCustomColorPicker = true
                        } label: {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 34, height: 34)
                                .overlay {
                                    Image(systemName: "plus")
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Add custom color")
                    }

                    if !customColors.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34), spacing: 12)], spacing: 12) {
                            ForEach(customColors.indices, id: \.self) { offset in
                                let combinedIndex = Self.colors.count + offset
                                colorSwatch(
                                    color: customColors[offset],
                                    isSelected: selectedColorIndex == combinedIndex,
                                    action: { selectedColorIndex = combinedIndex },
                                    onDelete: { deleteCustomColor(at: offset) }
                                )
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(22)
            .background(Color.black)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onSave(taskName, selectedColor)
                        dismiss()
                    }
                    .disabled(taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $isShowingCustomColorPicker) {
                CustomColorSheet(initialColor: selectedColor) { newColor in
                    customColors.append(newColor)
                    selectedColorIndex = Self.colors.count + customColors.count - 1
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func colorSwatch(
        color: Color,
        isSelected: Bool,
        action: @escaping () -> Void,
        onDelete: (() -> Void)? = nil
    ) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Circle()
                .fill(color)
                .frame(width: 34, height: 34)
                .overlay {
                    if isSelected {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                            .frame(width: 10, height: 10)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Task color")
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard onDelete != nil else { return }
                Haptics.impact(.rigid)
                onDelete?()
            }
        )
    }

    private func deleteCustomColor(at offset: Int) {
        let combinedIndex = Self.colors.count + offset
        customColors.remove(at: offset)
        if selectedColorIndex == combinedIndex {
            selectedColorIndex = 0
        } else if selectedColorIndex > combinedIndex {
            selectedColorIndex -= 1
        }
    }
}

private struct CustomColorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var color: Color
    @State private var hasSkippedInitialChange = false
    @State private var pendingCommitID = UUID()

    let onAdd: (Color) -> Void

    init(initialColor: Color, onAdd: @escaping (Color) -> Void) {
        _color = State(initialValue: initialColor)
        self.onAdd = onAdd
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Circle()
                    .fill(color)
                    .frame(width: 60, height: 60)

                ColorPicker("Pick a color", selection: $color, supportsOpacity: false)

                Spacer()
            }
            .padding(22)
            .background(Color.black)
            .navigationTitle("Custom Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Haptics.impact(.light)
                        onAdd(color)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(260)])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onChange(of: color) { _, newValue in
            // ColorPicker fires one spurious change right when it appears
            // (it normalizes the initial value), so the first change is ignored.
            guard hasSkippedInitialChange else {
                hasSkippedInitialChange = true
                return
            }
            let commitID = UUID()
            pendingCommitID = commitID
            Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard pendingCommitID == commitID else { return }
                Haptics.impact(.light)
                onAdd(newValue)
                dismiss()
            }
        }
    }
}

private enum AppTab: String, CaseIterable, Identifiable {
    case tasks
    case timeline
    case reports
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks:
            "Tasks"
        case .timeline:
            "Timeline"
        case .reports:
            "Reports"
        case .settings:
            "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .tasks:
            "checklist"
        case .timeline:
            "clock.fill"
        case .reports:
            "chart.bar.fill"
        case .settings:
            "gearshape.fill"
        }
    }
}

private extension Color {
    static let accentPurple = Color(red: 0.55, green: 0.38, blue: 0.96)
    static let selectedTabBackground = Color(red: 0.22, green: 0.22, blue: 0.22)
    static let tabBarBackground = Color(red: 0.09, green: 0.09, blue: 0.09)
}

#Preview {
    ContentView()
}
