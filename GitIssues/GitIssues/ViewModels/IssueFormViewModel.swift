//
//  IssueFormViewModel.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import Combine

@MainActor
class IssueFormViewModel: ObservableObject {
    // Form fields
    @Published var title: String = ""
    @Published var body: String = ""
    @Published var initialComment: String = ""
    @Published var selectedState: IssueState = .open
    @Published var selectedRepositoryId: String?
    @Published var availableRepositories: [Repository] = []
    @Published var isLoadingRepositories = false

    // Label management
    @Published var availableLabels: [Label] = []
    @Published var selectedLabelIds: Set<String> = []
    @Published var isLoadingLabels = false
    @Published var isCreatingLabel = false
    @Published var createLabelError: String?

    // UI state
    @Published var isSubmitting = false
    @Published var errorMessage: String?
    @Published var validationErrors: [String] = []

    // Dependencies
    private let apiService: GitHubAPIService
    private let mode: IssueFormMode

    // Original data for lightweight edit mode (used for comparison)
    private var originalIssueData: IssueFormWindowData.IssueData?
    private var repositoryOwner: String?
    private var repositoryName: String?

    // Hidden Kanban order marker parsed out of the body on load, re-injected on save.
    private var originalOrderKey: String?

    /// Repository of the most recently created or edited issue in this app session (issue #99).
    /// Deliberately in-memory only: a fresh launch starts with no repository selected.
    private static var lastUsedRepositoryId: String?

    /// The repository to pre-select in the New Issue form: the last-used repository, provided the
    /// user can still create issues in it. `nil` leaves the picker blank.
    static func defaultRepositoryId(lastUsed: String?, available: [Repository]) -> String? {
        guard let lastUsed, available.contains(where: { $0.id == lastUsed }) else { return nil }
        return lastUsed
    }

    // Form mode
    enum IssueFormMode {
        case create
        case edit(issue: Issue)
    }

    init(apiService: GitHubAPIService, mode: IssueFormMode) {
        self.apiService = apiService
        self.mode = mode

        // Pre-populate fields for edit mode
        switch mode {
        case .create:
            // Start with empty fields
            // Load repositories asynchronously
            break
        case .edit(let issue):
            self.title = issue.title
            self.originalOrderKey = KanbanOrderMarker.parse(from: issue.body)
            self.body = KanbanOrderMarker.strip(from: issue.body)
            self.selectedState = issue.state
            self.selectedRepositoryId = issue.repository.id
            // Pre-select existing labels
            self.selectedLabelIds = Set(issue.labels.map { $0.id })
        }
    }

    /// Lightweight initializer for window-based forms
    /// Creates the view model from lightweight data structures instead of full domain objects
    init(apiService: GitHubAPIService, mode: IssueFormMode, issueData: IssueFormWindowData.IssueData? = nil) {
        self.apiService = apiService
        self.mode = mode

        switch mode {
        case .create:
            // Start with empty fields
            break
        case .edit:
            if let data = issueData {
                self.title = data.title
                self.originalOrderKey = KanbanOrderMarker.parse(from: data.body)
                self.body = KanbanOrderMarker.strip(from: data.body)
                self.selectedState = IssueState(rawValue: data.state) ?? .open
                self.selectedRepositoryId = data.repositoryId
                self.selectedLabelIds = Set(data.labelIds)
                self.repositoryOwner = data.repositoryOwner
                self.repositoryName = data.repositoryName
                self.originalIssueData = data
            }
        }
    }

    /// Loads available repositories for create mode
    func loadRepositories() async {
        guard case .create = mode else { return }

        isLoadingRepositories = true
        do {
            availableRepositories = try await apiService.fetchAllRepositories()
        } catch {
            errorMessage = "Failed to load repositories: \(error.localizedDescription)"
        }

        // Default to the repository used for the last created/edited issue (#99).
        var preselected = false
        if selectedRepositoryId == nil,
           let defaultId = Self.defaultRepositoryId(lastUsed: Self.lastUsedRepositoryId, available: availableRepositories) {
            selectedRepositoryId = defaultId
            preselected = true
        }
        isLoadingRepositories = false

        // The picker's onChange only fires for user-driven changes, so load labels explicitly.
        if preselected {
            await loadLabels()
        }
    }

    /// Loads labels for the selected repository
    func loadLabels() async {
        // Get the repository info (owner and name)
        guard let repositoryId = selectedRepositoryId else {
            availableLabels = []
            return
        }

        // Get owner and name based on mode
        let owner: String?
        let name: String?

        switch mode {
        case .create:
            // Find the repository from available repositories
            if let repository = availableRepositories.first(where: { $0.id == repositoryId }) {
                owner = repository.owner.login
                name = repository.name
            } else {
                owner = nil
                name = nil
            }
        case .edit:
            // Use stored repository info from lightweight initializer
            owner = repositoryOwner
            name = repositoryName
        }

        guard let ownerLogin = owner, let repoName = name else {
            availableLabels = []
            return
        }

        isLoadingLabels = true
        do {
            // Hide Kanban state labels from normal label editing.
            let all = try await apiService.fetchAllRepositoryLabels(
                owner: ownerLogin,
                repo: repoName
            )
            availableLabels = Kanban.visibleLabels(all)
        } catch {
            errorMessage = "Failed to load labels: \(error.localizedDescription)"
        }
        isLoadingLabels = false
    }

    /// Returns true if in create mode
    var isCreateMode: Bool {
        switch mode {
        case .create:
            return true
        case .edit:
            return false
        }
    }

    /// Returns the issue being edited (if in edit mode)
    var editingIssue: Issue? {
        switch mode {
        case .create:
            return nil
        case .edit(let issue):
            return issue
        }
    }

    /// Creates a new label in the selected repository, adds it to availableLabels, and selects it
    func createLabel(name: String, color: String) async {
        guard let repositoryId = selectedRepositoryId else { return }

        isCreatingLabel = true
        createLabelError = nil

        do {
            let label = try await apiService.createLabel(
                repositoryId: repositoryId,
                name: name,
                color: color
            )
            // Don't surface Kanban state labels in the editor.
            if !Kanban.isKanbanLabel(label.name) {
                availableLabels.append(label)
                availableLabels.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
            selectedLabelIds.insert(label.id)
        } catch {
            createLabelError = error.localizedDescription
        }

        isCreatingLabel = false
    }

    /// Validates the form
    func validate() -> Bool {
        validationErrors.removeAll()

        // Validate title
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            validationErrors.append("Title is required")
        }

        // Validate repository selection (create mode only)
        if case .create = mode {
            if selectedRepositoryId == nil {
                validationErrors.append("Please select a repository")
            }
        }

        return validationErrors.isEmpty
    }

    /// Submits the form
    func submit() async throws -> Issue {
        // Clear previous errors
        errorMessage = nil

        // Validate
        guard validate() else {
            throw NSError(domain: "IssueFormViewModel", code: 400, userInfo: [
                NSLocalizedDescriptionKey: validationErrors.joined(separator: "\n")
            ])
        }

        isSubmitting = true

        do {
            var issue: Issue

            switch mode {
            case .create:
                guard let repositoryId = selectedRepositoryId else {
                    throw NSError(domain: "IssueFormViewModel", code: 400, userInfo: [
                        NSLocalizedDescriptionKey: "Repository is required"
                    ])
                }

                issue = try await apiService.createIssue(
                    repositoryId: repositoryId,
                    title: title,
                    body: body.isEmpty ? nil : body,
                    labelIds: selectedLabelIds.isEmpty ? nil : Array(selectedLabelIds)
                )

                // Add initial comment if provided
                let trimmedComment = initialComment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedComment.isEmpty {
                    _ = try await apiService.addComment(
                        issueId: issue.id,
                        body: trimmedComment
                    )
                }

            case .edit(let existingIssue):
                // Use original data if available (lightweight mode), otherwise use existing issue
                let originalTitle: String
                let originalBody: String?
                let originalState: IssueState
                let originalLabelIds: Set<String>
                let issueId: String

                if let originalData = originalIssueData {
                    // Lightweight mode - use stored original data
                    originalTitle = originalData.title
                    originalBody = originalData.body
                    originalState = IssueState(rawValue: originalData.state) ?? .open
                    originalLabelIds = Set(originalData.labelIds)
                    issueId = originalData.issueId
                } else {
                    // Full mode - use existing issue
                    originalTitle = existingIssue.title
                    originalBody = existingIssue.body
                    originalState = existingIssue.state
                    originalLabelIds = Set(existingIssue.labels.map { $0.id })
                    issueId = existingIssue.id
                }

                // Only send changed fields. Compare against the body with the hidden Kanban
                // order marker stripped, and re-inject that marker when sending an updated body
                // so manual board ordering survives an edit.
                let originalBodyStripped = KanbanOrderMarker.strip(from: originalBody)
                let normalizedCurrent = body.isEmpty ? nil : body
                let normalizedOriginal = originalBodyStripped.isEmpty ? nil : originalBodyStripped

                let titleChanged = title != originalTitle
                let bodyChanged = normalizedCurrent != normalizedOriginal
                let stateChanged = selectedState != originalState

                let bodyToSend: String?
                if bodyChanged {
                    if let key = originalOrderKey {
                        bodyToSend = KanbanOrderMarker.inject(key, into: body)
                    } else {
                        bodyToSend = normalizedCurrent
                    }
                } else {
                    bodyToSend = nil
                }

                issue = try await apiService.updateIssue(
                    issueId: issueId,
                    title: titleChanged ? title : nil,
                    body: bodyToSend,
                    state: stateChanged ? selectedState : nil
                )

                // Handle label changes
                let labelsToAdd = selectedLabelIds.subtracting(originalLabelIds)
                let labelsToRemove = originalLabelIds.subtracting(selectedLabelIds)
                let labelsChanged = !labelsToAdd.isEmpty || !labelsToRemove.isEmpty

                if !labelsToAdd.isEmpty {
                    try await apiService.addLabelsToIssue(
                        issueId: issueId,
                        labelIds: Array(labelsToAdd)
                    )
                }

                if !labelsToRemove.isEmpty {
                    try await apiService.removeLabelsFromIssue(
                        issueId: issueId,
                        labelIds: Array(labelsToRemove)
                    )
                }

                // Re-fetch issue to get updated labels
                if labelsChanged, let owner = repositoryOwner ?? existingIssue.repository.owner.login as String?,
                   let name = repositoryName ?? existingIssue.repository.name as String? {
                    let (refreshed, _) = try await apiService.fetchIssueDetail(
                        owner: owner,
                        repo: name,
                        number: issue.number
                    )
                    issue = refreshed
                }
            }

            // Remember the repository so the next New Issue form can default to it (#99).
            let usedRepositoryId = issue.repository.id.isEmpty
                ? (selectedRepositoryId ?? originalIssueData?.repositoryId)
                : issue.repository.id
            if let usedRepositoryId, !usedRepositoryId.isEmpty {
                Self.lastUsedRepositoryId = usedRepositoryId
            }

            isSubmitting = false
            return issue

        } catch {
            isSubmitting = false
            errorMessage = error.localizedDescription
            throw error
        }
    }
}
