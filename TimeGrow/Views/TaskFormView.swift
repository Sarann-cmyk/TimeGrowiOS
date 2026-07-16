//
//  TaskFormView.swift
//  TimeGrow
//

import SwiftUI

struct TaskFormView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var taskName: String
    @State private var customColors: [Color]
    @State private var selectedColorIndex: Int
    @State private var isShowingCustomColorPicker = false

    let navigationTitle: LocalizedStringKey
    let confirmTitle: LocalizedStringKey
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
        navigationTitle: LocalizedStringKey,
        confirmTitle: LocalizedStringKey,
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

struct CustomColorSheet: View {
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
