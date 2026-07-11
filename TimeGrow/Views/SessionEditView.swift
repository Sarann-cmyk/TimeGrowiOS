//
//  SessionEditView.swift
//  TimeGrow
//

import SwiftUI

struct SessionEditView: View {
    @EnvironmentObject private var taskService: TaskService
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @Environment(\.dismiss) private var dismiss

    private enum EditingField: Identifiable {
        case start, end
        var id: Int { self == .start ? 0 : 1 }
    }

    let session: TaskTimeSession

    @State private var startedAt: Date
    @State private var endedAt: Date
    @State private var selectedTaskID: String
    @State private var notes: String
    @State private var editingField: EditingField?
    @State private var isShowingTaskPicker = false
    @State private var isShowingDeleteConfirmation = false

    init(session: TaskTimeSession) {
        self.session = session
        _startedAt = State(initialValue: session.startedAt)
        _endedAt = State(initialValue: session.endedAt ?? Date())
        _selectedTaskID = State(initialValue: session.taskID)
        _notes = State(initialValue: session.notes ?? "")
    }

    private var selectedTask: TGTask? {
        taskService.tasks.first { $0.id == selectedTaskID }
    }

    private var isValid: Bool {
        endedAt > startedAt && selectedTask != nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    timeCard
                    taskRow
                    notesField
                    deleteButton
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Edit Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .sheet(item: $editingField) { field in
                dateTimePickerSheet(for: field)
            }
            .sheet(isPresented: $isShowingTaskPicker) {
                taskPickerSheet
            }
            .alert("Delete Session?", isPresented: $isShowingDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    Haptics.impact(.rigid)
                    taskService.deleteSession(session)
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Time card

    private var timeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                dateTimeColumn(title: "From", date: startedAt) { editingField = .start }
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 54)

                dateTimeColumn(title: "To", date: endedAt) { editingField = .end }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)
            }
            .padding(16)

            Divider().background(Color.white.opacity(0.08))

            HStack {
                Text("Duration")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                Spacer()
                Text(durationText)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(16)
        }
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(white: 0.08))
        }
    }

    private func dateTimeColumn(title: String, date: Date, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                Text(date.formatted(.dateTime.day().month(.wide).year()))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var durationText: String {
        let total = max(0, Int(endedAt.timeIntervalSince(startedAt)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%d:%02d", hours, minutes)
    }

    private func dateTimePickerSheet(for field: EditingField) -> some View {
        NavigationStack {
            DatePicker(
                "",
                selection: field == .start ? $startedAt : $endedAt,
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .padding()
            .navigationTitle(field == .start ? "From" : "To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { editingField = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    // MARK: - Task

    private var taskRow: some View {
        Button {
            Haptics.impact(.light)
            isShowingTaskPicker = true
        } label: {
            HStack {
                Text("Task")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)

                Spacer()

                if let selectedTask {
                    Circle()
                        .fill(selectedTask.color)
                        .frame(width: 20, height: 20)
                        .overlay {
                            Text(selectedTask.symbol)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    Text(selectedTask.name)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.08))
            }
        }
        .buttonStyle(.plain)
    }

    private var taskPickerSheet: some View {
        NavigationStack {
            List(taskService.tasks) { task in
                Button {
                    Haptics.selection()
                    selectedTaskID = task.id ?? selectedTaskID
                    isShowingTaskPicker = false
                } label: {
                    HStack {
                        Circle()
                            .fill(task.color)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Text(task.symbol)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        Text(task.name)
                            .foregroundStyle(.white)
                        Spacer()
                        if task.id == selectedTaskID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(accentColorManager.color)
                        }
                    }
                }
                .listRowBackground(Color.black)
            }
            .listStyle(.plain)
            .navigationTitle("Select Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingTaskPicker = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Notes

    private var notesField: some View {
        TextEditor(text: $notes)
            .scrollContentBackground(.hidden)
            .foregroundStyle(.white)
            .font(.system(size: 15))
            .frame(height: 140)
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(white: 0.08))
            }
            .overlay(alignment: .topLeading) {
                if notes.isEmpty {
                    Text("Notes")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
    }

    // MARK: - Delete

    private var deleteButton: some View {
        Button {
            Haptics.impact(.medium)
            isShowingDeleteConfirmation = true
        } label: {
            Text("Delete Session")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.08))
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private func save() {
        guard let selectedTask else { return }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        taskService.updateSession(
            session,
            startedAt: startedAt,
            endedAt: endedAt,
            task: selectedTask,
            notes: trimmedNotes.isEmpty ? nil : trimmedNotes
        )
        dismiss()
    }
}
