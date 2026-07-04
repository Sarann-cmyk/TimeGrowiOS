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
                        placeholderView("Settings")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            tabBar
        }
        .sheet(isPresented: $isShowingAddTask) {
            AddTaskView { name, color in
                taskService.createTask(name: name, color: color)
            }
            .presentationDetents([.height(260)])
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
        .padding(.horizontal, 24)
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
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(taskService.tasks) { task in
                            TaskRow(task: task) {
                                taskService.deleteTask(task)
                            }
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 26)
                    .padding(.bottom, 112)
                }
                .scrollIndicators(.hidden)
            }
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
                    selectedTab = tab
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
        .padding(.horizontal, 28)
        .padding(.bottom, 0)
        .offset(y: 10)
    }
}

private struct TaskRow: View {
    let task: TGTask
    let deleteAction: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(task.symbol.isEmpty ? "T" : task.symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(task.color, in: Circle())

            VStack(alignment: .leading, spacing: 5) {
                Text(task.name)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(formatDuration(task.totalTrackedSeconds()))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: deleteAction) {
                Image(systemName: "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete task")
        }
        .padding(.horizontal, 18)
        .frame(height: 76)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }
}

private struct AddTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var taskName = ""
    @State private var selectedColorIndex = 0

    let onCreate: (String, Color) -> Void

    private let colors: [Color] = [
        TGTask.defaultAccent,
        Color(red: 0.55, green: 0.38, blue: 0.96),
        Color(red: 0.19, green: 0.68, blue: 0.96),
        Color(red: 1.00, green: 0.56, blue: 0.26),
        Color(red: 0.97, green: 0.30, blue: 0.46),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                TextField("Task name", text: $taskName)
                    .font(.system(size: 18, weight: .medium))
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack(spacing: 12) {
                    ForEach(colors.indices, id: \.self) { index in
                        let color = colors[index]
                        Button {
                            selectedColorIndex = index
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 34, height: 34)
                                .overlay {
                                    if selectedColorIndex == index {
                                        Circle()
                                            .stroke(.white, lineWidth: 3)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Task color")
                    }
                }

                Spacer()
            }
            .padding(22)
            .background(Color.black)
            .navigationTitle("New Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(taskName, colors[selectedColorIndex])
                        dismiss()
                    }
                    .disabled(taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
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
