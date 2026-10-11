//
//  IssueLabelsSheet.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

/// "Labels…" dialog: lists every label in the issue's repository with the issue's current labels
/// ticked. Labels can be ticked/unticked, and a new label can be created with the + button (it is
/// added to the repository and selected automatically). Nothing is written until Save.
struct IssueLabelsSheet: View {
    let issue: Issue
    @ObservedObject var viewModel: IssuesListViewModel
    let onClose: () -> Void

    @State private var labels: [Label] = []
    @State private var selectedIds: Set<String> = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isCreating = false
    @State private var showingNewLabel = false
    @State private var errorMessage: String?

    private var filteredLabels: [Label] {
        guard !searchText.isEmpty else { return labels }
        return labels.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var hasChanges: Bool {
        let changes = LabelSelection.changes(current: issue.labels, selectedIds: selectedIds)
        return !changes.add.isEmpty || !changes.remove.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            searchBar

            Divider()

            content

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 6)
            }

            Divider()

            footer
        }
        .frame(width: 380, height: 480)
        .task { await loadLabels() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Labels")
                    .font(.headline)
                Text("#\(issue.number) \(issue.title)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !isLoading {
                Button {
                    showingNewLabel = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 16))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Create a new label in \(issue.repository.fullName)")
                .popover(isPresented: $showingNewLabel, arrowEdge: .trailing) {
                    NewLabelPopover(isCreating: isCreating, isPresented: $showingNewLabel) { name, color in
                        await createLabel(name: name, color: color)
                    }
                }
            }
        }
        .padding()
    }

    private var searchBar: some View {
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
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Loading labels...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if labels.isEmpty {
            Text("No labels in this repository yet. Use + to create one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLabels) { label in
                        LabelRow(
                            label: label,
                            isSelected: selectedIds.contains(label.id),
                            onToggle: { toggle(label) }
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selectedIds.count) selected")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Cancel") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Button("Save") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isLoading || isSaving || !hasChanges)

            if isSaving {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func toggle(_ label: Label) {
        if selectedIds.contains(label.id) {
            selectedIds.remove(label.id)
        } else {
            selectedIds.insert(label.id)
        }
    }

    private func loadLabels() async {
        do {
            labels = try await viewModel.fetchEditableLabels(for: issue.repository)
            selectedIds = Set(Kanban.visibleLabels(issue.labels).map(\.id))
        } catch {
            errorMessage = "Failed to load labels: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Creates the label in the repository, then adds it to the list already selected.
    private func createLabel(name: String, color: String) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        do {
            let label = try await viewModel.createLabel(in: issue.repository, name: name, color: color)
            labels.append(label)
            labels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            selectedIds.insert(label.id)
            return true
        } catch {
            errorMessage = "Failed to create label: \(error.localizedDescription)"
            return false
        }
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        do {
            let selected = labels.filter { selectedIds.contains($0.id) }
            try await viewModel.applyLabels(selected, to: issue)
            onClose()
        } catch {
            errorMessage = "Failed to update labels: \(error.localizedDescription)"
            isSaving = false
        }
    }
}
