//
//  ContentView.swift
//  TimeGrow
//
//  Created by Aleks Synelnyk on 03.07.2026.
//

import SwiftUI

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
                            sessions: taskService.sessions.filter { $0.taskID == task.id },
                            timerOwnerStatus: { taskService.timerOwnerStatus(for: task, at: $0) },
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

#Preview {
    ContentView()
}
