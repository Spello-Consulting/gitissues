//
//  NewLabelPopover.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

/// Popover for creating a new repository label (name + preset colour).
///
/// Shared by the issue form and the "Labels…" dialog. The caller performs the actual creation
/// in `onCreate`, which returns `true` on success so the popover can dismiss itself.
struct NewLabelPopover: View {
    let isCreating: Bool
    @Binding var isPresented: Bool
    let onCreate: (_ name: String, _ colorHex: String) async -> Bool

    @State private var labelName = ""
    @State private var selectedColor = LabelPresetColor.presets[0]
    @FocusState private var nameFieldFocused: Bool

    private var trimmedName: String {
        labelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Label")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("Label name", text: $labelName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFieldFocused)
                    .frame(width: 200)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 8), spacing: 6) {
                    ForEach(LabelPresetColor.presets) { preset in
                        Button {
                            selectedColor = preset
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color(hex: preset.hex))
                                    .frame(width: 22, height: 22)
                                if selectedColor.id == preset.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    Task {
                        if await onCreate(trimmedName, selectedColor.hex) {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || isCreating)

                if isCreating {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
        .onAppear { nameFieldFocused = true }
    }
}

struct LabelPresetColor: Identifiable {
    let id: String
    let hex: String

    static let presets: [LabelPresetColor] = [
        LabelPresetColor(id: "red",        hex: "d73a4a"),
        LabelPresetColor(id: "orange",     hex: "e4e669"),
        LabelPresetColor(id: "yellow",     hex: "fbca04"),
        LabelPresetColor(id: "green",      hex: "0075ca"),
        LabelPresetColor(id: "teal",       hex: "cfd3d7"),
        LabelPresetColor(id: "blue",       hex: "0052cc"),
        LabelPresetColor(id: "purple",     hex: "5319e7"),
        LabelPresetColor(id: "pink",       hex: "e99695"),
        LabelPresetColor(id: "brown",      hex: "b60205"),
        LabelPresetColor(id: "lime",       hex: "0e8a16"),
        LabelPresetColor(id: "indigo",     hex: "1d76db"),
        LabelPresetColor(id: "lightblue",  hex: "c2e0c6"),
        LabelPresetColor(id: "tan",        hex: "fef2c0"),
        LabelPresetColor(id: "mint",       hex: "bfdadc"),
        LabelPresetColor(id: "lavender",   hex: "d4c5f9"),
        LabelPresetColor(id: "gray",       hex: "c5def5"),
    ]
}
