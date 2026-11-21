//
//  IssueLabelsSheet.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

/// "Labels…" dialog for one or more issues, possibly spanning several repositories.
///
/// Every label name across the selected issues' repositories is listed with a tri-state checkbox:
/// checked (all issues have it), mixed (some do) or empty (none). Clicking changes it, and Save
/// applies only the labels the user changed — see `BatchLabelSelection`. Adding a label to an issue
/// in a repository that doesn't have it creates the label there first. A new label can be created
/// with the + button (in every selected repository that lacks it). Nothing is written until Save.
struct IssueLabelsSheet: View {
    let issues: [Issue]
    @ObservedObject var viewModel: IssuesListViewModel
    let onClose: () -> Void

    /// Editable labels per repository ID.
    @State private var repoLabels: [String: [Label]] = [:]
    @State private var union: [UnionLabel] = []
    @State private var initialStates: [String: LabelCheckState] = [:]
    /// What the user has changed, keyed by label key. Absent = untouched.
    @State private var intents: [String: LabelIntent] = [:]
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isSaving = false
    @State private var isCreating = false
    @State private var showingNewLabel = false
    @State private var errorMessage: String?

    /// The distinct repositories of the selected issues, ordered by name.
    private var repositories: [Repository] {
        var seen = Set<String>()
        return issues.map(\.repository)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending }
    }

    private var filteredLabels: [UnionLabel] {
        guard !searchText.isEmpty else { return union }
        return union.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var plan: [IssueLabelChange] {
        BatchLabelSelection.plan(issues: issues, intents: intents)
    }

    private var hasChanges: Bool { !plan.isEmpty }

    /// Labels Save will create first, e.g. "'triage' will be created in owner/b".
    private var creationNotice: String? {
        let creations = BatchLabelSelection.missingLabels(plan: plan, repoLabels: repoLabels, union: union)
        guard !creations.isEmpty else { return nil }
        let byName = Dictionary(grouping: creations, by: \.name)
        return byName.keys.sorted().map { name in
            let repos = (byName[name] ?? []).map(\.repository.fullName).sorted().joined(separator: ", ")
            return "'\(name)' will be created in \(repos)."
        }.joined(separator: " ")
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

            if let creationNotice {
                Text(creationNotice)
                    .font(.caption)
                    .foregroundColor(.secondary)
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

    private var subtitle: String {
        if let issue = issues.first, issues.count == 1 {
            return "#\(issue.number) \(issue.title)"
        }
        let repoCount = repositories.count
        return "\(issues.count) issues in \(repoCount) \(repoCount == 1 ? "repository" : "repositories")"
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Labels")
                    .font(.headline)
                Text(subtitle)
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
                .help(repositories.count == 1
                          ? "Create a new label in \(repositories[0].fullName)"
                          : "Create a new label in each selected repository that lacks it")
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
        } else if loadFailed {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if union.isEmpty {
            Text("No labels yet. Use + to create one.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredLabels) { label in
                        let state = BatchLabelSelection.displayState(
                            initial: initialStates[label.key] ?? .none,
                            intent: intents[label.key]
                        )
                        LabelRow(
                            label: Label(id: label.key, name: label.name, color: label.color),
                            isSelected: state == .all,
                            onToggle: { toggle(label) },
                            isMixed: state == .mixed,
                            caption: caption(for: label)
                        )
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(hasChanges ? "\(plan.count) of \(issues.count) issue\(issues.count == 1 ? "" : "s") will change" : "No changes")
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
            .disabled(isLoading || loadFailed || isSaving || !hasChanges)

            if isSaving {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding()
    }

    // MARK: - Actions

    /// "in 2 of 3 repositories" for a label that only some of the selected repositories have.
    private func caption(for label: UnionLabel) -> String? {
        let total = repositories.count
        guard total > 1, label.repositoryIDs.count < total else { return nil }
        return "in \(label.repositoryIDs.count) of \(total) repositories"
    }

    private func toggle(_ label: UnionLabel) {
        intents[label.key] = BatchLabelSelection.nextIntent(
            current: intents[label.key],
            initial: initialStates[label.key] ?? .none
        )
    }

    /// Rebuilds the label list and each label's current state from `repoLabels`.
    private func rebuildLabels() {
        union = BatchLabelSelection.unionLabels(repositories.map { ($0.id, repoLabels[$0.id] ?? []) })
        initialStates = Dictionary(
            union.map { ($0.key, BatchLabelSelection.state(ofLabelKey: $0.key, in: issues)) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func loadLabels() async {
        do {
            var loaded: [String: [Label]] = [:]
            for repository in repositories {
                loaded[repository.id] = try await viewModel.fetchEditableLabels(for: repository)
            }
            repoLabels = loaded
            rebuildLabels()
        } catch {
            // A partial list could make us try to create labels that already exist, so give up.
            loadFailed = true
            errorMessage = "Failed to load labels: \(error.localizedDescription)"
        }
        isLoading = false
    }

    /// Creates the label in every selected repository that lacks it, then marks it to be added.
    private func createLabel(name: String, color: String) async -> Bool {
        isCreating = true
        defer { isCreating = false }
        errorMessage = nil
        let labelKey = BatchLabelSelection.key(name)
        let creations = repositories
            .filter { repo in !(repoLabels[repo.id] ?? []).contains { BatchLabelSelection.key($0.name) == labelKey } }
            .map { RepoLabelCreation(repository: $0, name: name, color: color) }
        let result = await viewModel.createLabels(creations)
        for (repoID, labels) in result.created {
            repoLabels[repoID, default: []].append(contentsOf: labels)
        }
        rebuildLabels()
        if !result.failures.isEmpty {
            errorMessage = "Failed to create label:\n" + result.failures.joined(separator: "\n")
        }
        guard creations.isEmpty || !result.created.isEmpty else { return false }
        intents[labelKey] = .add
        return true
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        let changes = plan

        // Repositories that lack a label being added get it created first.
        var labelsByRepo = repoLabels
        let creations = BatchLabelSelection.missingLabels(plan: changes, repoLabels: repoLabels, union: union)
        var failures: [String] = []
        if !creations.isEmpty {
            let result = await viewModel.createLabels(creations)
            for (repoID, labels) in result.created {
                labelsByRepo[repoID, default: []].append(contentsOf: labels)
            }
            failures = result.failures
        }
        let failureText = failures.isEmpty ? nil : "Failed to create labels:\n" + failures.joined(separator: "\n")

        if issues.count == 1, let change = changes.first {
            // Single issue: apply now so errors show in the dialog.
            if let failureText {
                errorMessage = failureText
                isSaving = false
                return
            }
            do {
                try await viewModel.applyLabelChange(change, repoLabels: labelsByRepo, refreshDetail: true)
                onClose()
            } catch {
                errorMessage = "Failed to update labels: \(error.localizedDescription)"
                isSaving = false
            }
            return
        }

        // Several issues: run in the background queue (progress bar), carrying on past failures.
        viewModel.enqueueBatchLabels(changes, repoLabels: labelsByRepo)
        if let failureText {
            viewModel.errorMessage = failureText
        }
        onClose()
    }
}
