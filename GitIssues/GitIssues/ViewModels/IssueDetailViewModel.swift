//
//  IssueDetailViewModel.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import Combine
import AppKit

@MainActor
class IssueDetailViewModel: ObservableObject {
    @Published var issue: Issue
    @Published var comments: [Comment] = []
    /// GitHub activity log (labels, close/reopen, ...). Empty when the setting is off.
    @Published var activity: [IssueActivity] = []
    /// Set when the activity log couldn't be loaded, so the panel can say so.
    @Published var activityError: String?
    @Published var isLoadingComments = false
    @Published var errorMessage: String?
    @Published var isPinned: Bool

    let apiService: GitHubAPIService
    private let pinningService: PinningService
    private weak var listViewModel: IssuesListViewModel?

    init(issue: Issue, apiService: GitHubAPIService, pinningService: PinningService, listViewModel: IssuesListViewModel? = nil) {
        self.issue = issue
        self.apiService = apiService
        self.pinningService = pinningService
        self.listViewModel = listViewModel
        self.isPinned = pinningService.isPinned(issue.id)
    }

    /// Loads the full issue details with comments
    func loadIssueDetails(afterDelay delay: TimeInterval = 0, allowRetry: Bool = true) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        isLoadingComments = true
        errorMessage = nil

        do {
            // Fetch the activity log alongside the issue; a failure here never blocks the issue.
            async let fetchedActivity = fetchActivityIfEnabled()

            let (updatedIssue, fetchedComments) = try await apiService.fetchIssueDetail(
                owner: issue.repository.owner.login,
                repo: issue.repository.name,
                number: issue.number
            )

            self.issue = updatedIssue
            applyActivity(await fetchedActivity)

            // Work around eventual consistency: if we previously had comments and the fetch returns empty,
            // keep existing comments and retry once after a short delay.
            if fetchedComments.isEmpty, !self.comments.isEmpty, allowRetry {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    await self?.loadIssueDetails(afterDelay: 0, allowRetry: false)
                }
                return
            }

            self.comments = fetchedComments
        } catch GraphQLError.notFound {
            // GitHub says this issue no longer exists (deleted or transferred elsewhere). Drop it
            // from the list now rather than waiting for the next full sync; the list selection
            // follows `allIssues`, so this also closes the detail pane.
            AppLogger.shared.info("Issue #\(issue.number) no longer exists on GitHub; removing it from the list")
            listViewModel?.removeIssueFromCache(id: issue.id)
            errorMessage = GraphQLError.notFound.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoadingComments = false
    }

    /// Fetches the activity log if the setting is on. Returns `nil` when disabled or on failure,
    /// so callers keep whatever they already have.
    private func fetchActivityIfEnabled() async -> Result<[IssueActivity], Error>? {
        guard AppStateService.showIssueActivity else { return nil }
        do {
            let events = try await apiService.fetchIssueActivity(
                owner: issue.repository.owner.login,
                repo: issue.repository.name,
                number: issue.number
            )
            AppLogger.shared.info("Loaded \(events.count) activity event(s) for #\(issue.number)")
            return .success(events)
        } catch {
            AppLogger.shared.error("Failed to load activity for #\(issue.number): \(error.localizedDescription)")
            return .failure(error)
        }
    }

    /// Applies a fetch result: `nil` means the setting is off (clear), a failure keeps whatever
    /// was already loaded and records the error for display.
    private func applyActivity(_ result: Result<[IssueActivity], Error>?) {
        switch result {
        case .none:
            activity = []
            activityError = nil
        case .success(let events):
            activity = events
            activityError = nil
        case .failure(let error):
            activityError = error.localizedDescription
        }
    }

    /// Loads (or clears, if the setting is now off) the activity log on its own, e.g. when the
    /// user turns the setting on while an issue is open.
    func loadActivity() async {
        applyActivity(await fetchActivityIfEnabled())
    }

    /// Toggles the pin state for this issue
    func togglePin() {
        pinningService.togglePin(issue.id)
        isPinned = pinningService.isPinned(issue.id)

        // Update the list view model's pinned IDs
        listViewModel?.pinnedIssueIDs = pinningService.getPinnedIssues()
    }

    /// Refreshes the main issues list
    func refreshList(afterDelay delay: TimeInterval = 0) async {
        await listViewModel?.loadIssues(afterDelay: delay)
    }

    /// Deletes a comment
    func deleteComment(_ comment: Comment) async {
        // Optimistic: remove from list immediately
        let previousComments = comments
        comments.removeAll { $0.id == comment.id }

        do {
            try await apiService.deleteComment(commentId: comment.id)
        } catch {
            // Revert on failure
            comments = previousComments
            errorMessage = error.localizedDescription
        }
    }

    /// Shares the issue by copying its GitHub URL to the clipboard
    func shareIssue() {
        let owner = issue.repository.owner.login
        let repo = issue.repository.name
        let number = issue.number
        let url = "https://github.com/\(owner)/\(repo)/issues/\(number)"

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)
    }

    /// Closes the issue (sets state to closed). Any managed Kanban label is removed in the same
    /// request so the closed issue lands in the Done column.
    func closeIssue() async {
        do {
            let updatedIssue = try await apiService.closeIssue(
                issue,
                managedLabelNames: KanbanSettingsService.shared.managedLabelNames
            )
            self.issue = updatedIssue
            listViewModel?.upsertIssueInCache(updatedIssue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Reopens the issue (sets state to open)
    func reopenIssue() async {
        do {
            let updatedIssue = try await apiService.updateIssue(
                issueId: issue.id,
                title: nil,
                body: nil,
                state: .open
            )
            self.issue = updatedIssue
            listViewModel?.upsertIssueInCache(updatedIssue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sets the assignees for the issue
    func setAssignees(_ assignees: [User]) async {
        do {
            try await apiService.setIssueAssignees(
                issueId: issue.id,
                currentAssigneeIds: issue.assignees.map { $0.id },
                newAssigneeIds: assignees.map { $0.id }
            )
            let updatedIssue = Issue(
                id: issue.id,
                number: issue.number,
                title: issue.title,
                body: issue.body,
                state: issue.state,
                createdAt: issue.createdAt,
                updatedAt: issue.updatedAt,
                repository: issue.repository,
                labels: issue.labels,
                assignees: assignees,
                author: issue.author
            )
            self.issue = updatedIssue
            listViewModel?.upsertIssueInCache(updatedIssue)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the issue
    func deleteIssue() async {
        do {
            try await apiService.deleteIssue(issueId: issue.id)
            listViewModel?.removeIssueFromCache(id: issue.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

