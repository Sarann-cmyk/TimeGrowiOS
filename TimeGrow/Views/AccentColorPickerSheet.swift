//
//  AccentColorPickerSheet.swift
//  TimeGrow
//

import SwiftUI

struct AccentColorPickerSheet: View {
    @EnvironmentObject private var accentColorManager: AccentColorManager
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 5)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(AccentColorManager.presetHexes, id: \.self) { hex in
                        colorButton(hex: hex, isSelected: accentColorManager.selectedHex.caseInsensitiveCompare(hex) == .orderedSame)
                    }
                }
                .padding(20)
            }
            .background(Color.black)
            .navigationTitle("Accent Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium])
    }

    private func colorButton(hex: String, isSelected: Bool) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.easeInOut(duration: 0.2)) {
                accentColorManager.selectedHex = hex
            }
        } label: {
            ZStack {
                Circle()
                    .fill(TaskAppearance.color(fromHex: hex))
                    .frame(width: 44, height: 44)

                if isSelected {
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 2.5)
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Selected accent color" : hex)
    }
}

#Preview {
    AccentColorPickerSheet()
        .environmentObject(AccentColorManager())
}
