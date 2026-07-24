//
//  ContentView.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI
import UniformTypeIdentifiers

private enum TaskListDisplayMode: String {
    case list
    case tile
}

struct ContentView: View {
    @EnvironmentObject private var taskService: TaskService
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @EnvironmentObject private var languageManager: LanguageManager
    @Environment(\.locale) private var locale

    @AppStorage("settings.taskListDisplayMode") private var taskListDisplayModeRawValue = TaskListDisplayMode.list.rawValue
    @State private var selectedTab: AppTab = .tasks
    @State private var isShowingAddTask = false
    @State private var taskBeingEdited: TGTask?
    @State private var taskForAutoTracking: TGTask?
    @State private var isReorderingTasks = false
    @State private var reorderedTasks: [TGTask] = []
    @State private var draggedTask: TGTask?

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
                        TimelineTabView()
                    case .reports:
                        ReportsView()
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
        .sheet(item: $taskForAutoTracking) { task in
            AutoTrackingPickerView(task: task)
        }
        .onAppear {
            DiagnosticsLog.log(
                "language",
                "ContentView appeared current=\(languageManager.current.rawValue) environmentLocale=\(locale.identifier) selectedTab=\(selectedTab.rawValue)"
            )
        }
        .onChange(of: languageManager.current) { oldLanguage, newLanguage in
            DiagnosticsLog.log(
                "language",
                "ContentView observed change old=\(oldLanguage.rawValue) new=\(newLanguage.rawValue) environmentLocale=\(locale.identifier) selectedTab=\(selectedTab.rawValue)"
            )
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var header: some View {
        if selectedTab != .reports && selectedTab != .timeline {
            HStack(alignment: .center) {
                Text(selectedTab.title)
                    .font(.system(size: 38, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                    .minimumScaleFactor(0.75)

                Spacer()

                if selectedTab == .tasks {
                    if isReorderingTasks {
                        Button {
                            Haptics.impact(.light)
                            withAnimation { isReorderingTasks = false }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            Haptics.impact(.rigid)
                            taskService.reorderTasks(reorderedTasks)
                            withAnimation { isReorderingTasks = false }
                        } label: {
                            Text("Save")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(accentColorManager.color)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 14)
                    } else {
                        Menu {
                            Button {
                                Haptics.selection()
                                taskListDisplayModeRawValue = TaskListDisplayMode.list.rawValue
                            } label: {
                                Label("List View", systemImage: "list.bullet")
                            }
                            Button {
                                Haptics.selection()
                                taskListDisplayModeRawValue = TaskListDisplayMode.tile.rawValue
                            } label: {
                                Label("Tile View", systemImage: "square.grid.2x2")
                            }
                            Divider()
                            Button {
                                Haptics.impact(.medium)
                                reorderedTasks = taskService.tasks
                                withAnimation { isReorderingTasks = true }
                            } label: {
                                Label("Change Order", systemImage: "arrow.up.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 25, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 42)
                        }
                        .accessibilityLabel("Task list options")

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
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .frame(height: 65, alignment: .bottom)
        }
    }

    private var taskListDisplayMode: TaskListDisplayMode {
        TaskListDisplayMode(rawValue: taskListDisplayModeRawValue) ?? .list
    }

    private var tasksView: some View {
        Group {
            if !taskService.hasReceivedInitialTasksSnapshot {
                ProgressView()
                    .controlSize(.large)
                    .tint(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 88)
            } else if taskService.tasks.isEmpty {
                Text(LanguageManager.localized("No tasks yet"))
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 76)
            } else {
                let displayedTasks = isReorderingTasks ? reorderedTasks : taskService.tasks

                ScrollView {
                    switch taskListDisplayMode {
                    case .list:
                        LazyVStack(spacing: 11) {
                            ForEach(displayedTasks) { task in
                                TaskRow(
                                    task: task,
                                    sessions: taskService.sessions.filter { $0.taskID == task.id },
                                    timerOwnerStatus: { taskService.timerOwnerStatus(for: task, at: $0) },
                                    onToggleTimer: { toggleTimer(task) },
                                    stopAutoTrackAction: { taskService.stopAutoTracking(for: task) },
                                    editAction: { taskBeingEdited = task },
                                    deleteAction: { taskService.deleteTask(task) },
                                    autoTrackAction: { taskForAutoTracking = task },
                                    isReorderModeActive: isReorderingTasks
                                )
                                .modifier(reorderDragModifier(for: task))
                            }
                        }
                        .padding(.horizontal, 21)
                        .padding(.top, 31)
                        .padding(.bottom, 112)
                    case .tile:
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 11) {
                            ForEach(displayedTasks) { task in
                                TaskTile(
                                    task: task,
                                    sessions: taskService.sessions.filter { $0.taskID == task.id },
                                    timerOwnerStatus: { taskService.timerOwnerStatus(for: task, at: $0) },
                                    onToggleTimer: { toggleTimer(task) },
                                    stopAutoTrackAction: { taskService.stopAutoTracking(for: task) },
                                    editAction: { taskBeingEdited = task },
                                    deleteAction: { taskService.deleteTask(task) },
                                    autoTrackAction: { taskForAutoTracking = task },
                                    isReorderModeActive: isReorderingTasks
                                )
                                .modifier(reorderDragModifier(for: task))
                            }
                        }
                        .padding(.horizontal, 21)
                        .padding(.top, 31)
                        .padding(.bottom, 112)
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(isReorderingTasks ? .basedOnSize : .always)
            }
        }
    }

    private func reorderDragModifier(for task: TGTask) -> some ViewModifier {
        TaskReorderDragModifier(
            task: task,
            isActive: isReorderingTasks,
            items: $reorderedTasks,
            draggedTask: $draggedTask
        )
    }

    private func toggleTimer(_ task: TGTask) {
        if task.isTimerRunning {
            taskService.stopTimer(for: task)
        } else {
            taskService.startTimer(for: task)
        }
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
                    Image(systemName: tab.systemImage)
                        .font(.system(size: tab == .tasks ? 20 : 23, weight: .bold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(selectedTab == tab ? accentColorManager.color : .white)
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

/// Enables drag-to-reorder for a single row/tile while "Change Order" mode is active —
/// a no-op wrapper otherwise, so normal browsing isn't affected.
private struct TaskReorderDragModifier: ViewModifier {
    let task: TGTask
    let isActive: Bool
    @Binding var items: [TGTask]
    @Binding var draggedTask: TGTask?

    func body(content: Content) -> some View {
        if isActive {
            content
                .opacity(draggedTask?.id == task.id ? 0.4 : 1)
                .onDrag {
                    draggedTask = task
                    return NSItemProvider(object: (task.id ?? "") as NSString)
                }
                .onDrop(
                    of: [.text],
                    delegate: TaskReorderDropDelegate(item: task, items: $items, draggedTask: $draggedTask)
                )
        } else {
            content
        }
    }
}

private struct TaskReorderDropDelegate: DropDelegate {
    let item: TGTask
    @Binding var items: [TGTask]
    @Binding var draggedTask: TGTask?

    func dropEntered(info: DropInfo) {
        guard let draggedTask,
              draggedTask.id != item.id,
              let fromIndex = items.firstIndex(where: { $0.id == draggedTask.id }),
              let toIndex = items.firstIndex(where: { $0.id == item.id })
        else { return }

        withAnimation(.default) {
            items.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex
            )
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedTask = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

#Preview {
    ContentView()
        .environmentObject(TaskService())
        .environmentObject(AccentColorManager())
        .environmentObject(LanguageManager())
}
