//
//  LabelSelectorSheet.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

struct LabelSelectorSheet: View {
    @ObservedObject var viewModel: IssuesListViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var filteredLabels: [Label] {
        if searchText.isEmpty {
            return viewModel.availableLabels
        }
        return viewModel.availableLabels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    var selectedCount: Int {
        viewModel.filterOptions.selectedLabels.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Filter by Label")
                    .font(.headline)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter labels", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .padding(.horizontal)
            .padding(.top, 8)

            // Selection summary and clear button
            if selectedCount > 0 {
                HStack {
                    Text("\(selectedCount) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Clear All") {
                        viewModel.clearLabelFilter()
                    }
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }

            Divider()

            // Label list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLabels) { label in
                        LabelRow(
                            label: label,
                            isSelected: viewModel.filterOptions.selectedLabels.contains(label.id),
                            onToggle: {
                                viewModel.toggleLabel(label.id)
                            }
                        )
                        Divider()
                    }
                }
            }

            Divider()

            // Done button
            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
        }
        .frame(width: 350, height: 450)
    }
}

struct LabelRow: View {
    let label: Label
    let isSelected: Bool
    let onToggle: () -> Void
    /// Tri-state support for multi-issue label editing: some (not all) issues have the label.
    var isMixed = false
    /// Optional secondary text shown after the label, e.g. "in 2 of 3 repositories".
    var caption: String?

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isMixed ? "minus.circle.fill" : (isSelected ? "checkmark.circle.fill" : "circle"))
                    .foregroundColor(isSelected || isMixed ? .accentColor : .secondary)
                    .font(.title3)

                Text(label.name)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(hex: label.color).opacity(0.2))
                    .foregroundColor(Color(hex: label.color))
                    .cornerRadius(4)

                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
