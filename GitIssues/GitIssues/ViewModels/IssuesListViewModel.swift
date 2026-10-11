//
//  IssuesListViewModel.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import Combine

@MainActor
class IssuesListViewModel: ObservableObject {
    @Published var allIssues: [Issue] = []
    @Published var filteredIssues: [Issue] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var filterOptions = FilterOptions()
    @Published var pinnedIssueIDs: Set<String> = []
    @Published var viewerLogin: String?

    private let apiService: GitHubAPIService
    let pinningService: PinningService // Made public so detail view can access it
    /// Serial queue for background GitHub mutations; drives the bottom progress bar.
    let taskQueue = BackgroundTaskQueue()
    private let appStateService = AppStateService()
    private var cancellables = Set<AnyCancellable>()
    private var syncTask: Task<Void, Never>?

    // Track mutations that are ahead of any in-flight background sync
    private var pendingDeletions: Set<String> = []
    private var pendingInsertions: [Issue] = []
    /// Local edits that an in-flight or very recent sync may not reflect yet (issue #100).
    private var pendingUpdates: [String: PendingIssueUpdate] = [:]
    /// Monotonic ids for list fetches, so a slow response can't clobber a newer one.
    private var fetchSequence = 0
    private var lastAppliedFetchSequence = 0

    init(accessToken: String) {
        self.apiService = GitHubAPIService(accessToken: accessToken)
        self.pinningService = PinningService()
        self.pinnedIssueIDs = pinningService.getPinnedIssues()

        // Restore saved filter state
        if let savedFilterOptions = appStateService.loadFilterState() {
            self.filterOptions = savedFilterOptions
        }

        // Observe filter changes and refilter
        Publishers.CombineLatest4($filterOptions, $allIssues, $pinnedIssueIDs, $viewerLogin)
            .map { filterOptions, allIssues, pinnedIDs, viewerLogin in
                Self.applyFiltersAndSort(filterOptions: filterOptions, to: allIssues, pinnedIDs: pinnedIDs, viewerLogin: viewerLogin)
            }
            .assign(to: &$filteredIssues)

        // Save filter state whenever it changes
        $filterOptions
            .dropFirst() // Skip initial value
            .sink { [weak self] newFilterOptions in
                self?.appStateService.saveFilterState(newFilterOptions)
            }
            .store(in: &cancellables)

        // Ensure the read-only preference reflects the current setting.
        filterOptions.allowReadOnly = AppStateService.allowReadOnlyRepoAccess

        // React to the "Allow read-only repository access" setting changing in Settings.
        NotificationCenter.default.publisher(for: .allowReadOnlyRepoAccessChanged)
            .sink { [weak self] _ in
                guard let self else { return }
                self.filterOptions.allowReadOnly = AppStateService.allowReadOnlyRepoAccess
                Task { await self.loadIssues() }
            }
            .store(in: &cancellables)
    }

    /// Loads all issues from the API. Shows a full-screen spinner on first load;
    /// on subsequent loads keeps existing data visible while refreshing in the background.
    func loadIssues(afterDelay delay: TimeInterval = 0) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        // First load: show full-screen spinner. Subsequent loads: keep list visible.
        if allIssues.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        errorMessage = nil

        do {
            // Fetch viewer login if not already fetched
            if viewerLogin == nil {
                viewerLogin = try await apiService.fetchViewerLogin()
            }

            // Fetch all issues regardless of state/visibility — filtering is done client-side
            let count = try await fetchAndApplyIssues()
            AppLogger.shared.info("Loaded \(count) issues from GitHub")
        } catch {
            AppLogger.shared.error("Failed to load issues: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
        isRefreshing = false
    }

    // MARK: - Background Sync

    func startBackgroundSync() {
        stopBackgroundSync()
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let enabled = AppStateService.isSyncEnabled
                let interval = AppStateService.syncIntervalSeconds
                guard enabled, interval > 0 else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.syncIssuesSilently()
            }
        }
    }

    func stopBackgroundSync() {
        syncTask?.cancel()
        syncTask = nil
    }

    private func syncIssuesSilently() async {
        guard !isLoading, !isRefreshing else { return }
        do {
            if viewerLogin == nil {
                viewerLogin = try await apiService.fetchViewerLogin()
            }
            _ = try await fetchAndApplyIssues()
        } catch {
            // Silent sync — don't surface transient errors
        }
    }

    /// Fetches all issues and merges them into the cache. Returns the number of issues fetched.
    ///
    /// The fetch is stamped with its start time and a sequence number so the merge can tell
    /// whether the response predates a local edit (see `IssueSyncMerger`), and so a response that
    /// arrives after a newer fetch has already been applied is discarded rather than rolling the
    /// list back.
    private func fetchAndApplyIssues() async throws -> Int {
        fetchSequence += 1
        let sequence = fetchSequence
        let startedAt = Date()

        let issues = try await apiService.fetchAllIssues()

        guard sequence > lastAppliedFetchSequence else { return issues.count }
        lastAppliedFetchSequence = sequence
        applyIssuesFromSync(issues, fetchStartedAt: startedAt)
        return issues.count
    }

    /// Merges API-returned issues with any pending local mutations that may have raced ahead
    /// of an in-flight sync: re-injects unconfirmed insertions, filters out pending deletions,
    /// and keeps locally-edited issues that the response doesn't reflect yet.
    private func applyIssuesFromSync(_ issues: [Issue], fetchStartedAt: Date) {
        let incomingIDs = Set(issues.map { $0.id })

        // Confirmed absent → deletion acknowledged, stop filtering
        pendingDeletions = pendingDeletions.filter { incomingIDs.contains($0) }
        // Confirmed present → insertion acknowledged, stop prepending
        pendingInsertions = pendingInsertions.filter { !incomingIDs.contains($0.id) }

        let merged = IssueSyncMerger.merge(
            incoming: issues,
            pending: &pendingUpdates,
            fetchStartedAt: fetchStartedAt
        )
        let filtered = merged.filter { !pendingDeletions.contains($0.id) }
        allIssues = pendingInsertions + filtered
    }

    // MARK: - Cache Mutations

    /// Inserts or updates an issue in the local cache without a full reload.
    /// If the issue already exists it is updated in place; otherwise it is inserted at the front.
    func upsertIssueInCache(_ issue: Issue) {
        // Protect this edit from any sync response that doesn't reflect it yet.
        pendingUpdates[issue.id] = PendingIssueUpdate(issue: issue, appliedAt: Date())

        if let index = allIssues.firstIndex(where: { $0.id == issue.id }) {
            allIssues[index] = issue
            // Keep an unconfirmed insertion's copy in step so a sync doesn't re-inject the old one.
            if let pendingIndex = pendingInsertions.firstIndex(where: { $0.id == issue.id }) {
                pendingInsertions[pendingIndex] = issue
            }
        } else {
            allIssues.insert(issue, at: 0)
            pendingInsertions.insert(issue, at: 0)
        }
    }

    /// Removes an issue from the local cache without a full reload.
    func removeIssueFromCache(id: String) {
        allIssues.removeAll { $0.id == id }
        pendingInsertions.removeAll { $0.id == id }
        pendingUpdates[id] = nil
        pendingDeletions.insert(id)
    }

    /// Removes any managed `kanban-<Status>` labels currently on the issue, so an issue closed
    /// outside the Kanban board resolves to the Done (closed) column instead of lingering in its
    /// old column. No-op when the issue carries no managed Kanban labels. Other users' `kanban-*`
    /// labels (not part of this config) are left intact, mirroring `performKanbanMove`.
    func clearManagedKanbanLabels(on issue: Issue) async {
        let managed = KanbanSettingsService.shared.managedLabelNames
        let labelsToRemove = issue.labels.filter { managed.contains($0.name.lowercased()) }
        guard !labelsToRemove.isEmpty else { return }
        do {
            try await apiService.removeLabelsFromIssue(issueId: issue.id, labelIds: labelsToRemove.map { $0.id })
        } catch {
            AppLogger.shared.error("Failed to clear kanban labels on #\(issue.number): \(error.localizedDescription)")
        }
    }

    /// Closes an issue via the API and immediately updates the local cache.
    func closeIssue(_ issue: Issue) async {
        do {
            // Clear the managed Kanban label first so the closed issue lands in the Done column.
            await clearManagedKanbanLabels(on: issue)
            let updatedIssue = try await apiService.updateIssue(issueId: issue.id, title: nil, body: nil, state: .closed)
            upsertIssueInCache(updatedIssue)
            AppLogger.shared.info("Closed issue #\(issue.number) (\(issue.repository.fullName))")
        } catch {
            AppLogger.shared.error("Failed to close issue #\(issue.number): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Reopens an issue via the API and immediately updates the local cache.
    func reopenIssue(_ issue: Issue) async {
        do {
            let updatedIssue = try await apiService.updateIssue(issueId: issue.id, title: nil, body: nil, state: .open)
            upsertIssueInCache(updatedIssue)
            AppLogger.shared.info("Reopened issue #\(issue.number) (\(issue.repository.fullName))")
        } catch {
            AppLogger.shared.error("Failed to reopen issue #\(issue.number): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes an issue via the API and immediately removes it from the local cache.
    func deleteIssue(_ issue: Issue) async {
        do {
            try await apiService.deleteIssue(issueId: issue.id)
            removeIssueFromCache(id: issue.id)
            AppLogger.shared.info("Deleted issue #\(issue.number) (\(issue.repository.fullName))")
        } catch {
            AppLogger.shared.error("Failed to delete issue #\(issue.number): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Updates assignees for an issue via the API and immediately updates the local cache.
    func assignIssue(_ issue: Issue, assignees: [User]) async {
        do {
            try await apiService.setIssueAssignees(
                issueId: issue.id,
                currentAssigneeIds: issue.assignees.map { $0.id },
                newAssigneeIds: assignees.map { $0.id }
            )
            let updated = Issue(
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
            upsertIssueInCache(updated)
            AppLogger.shared.info("Updated assignees for issue #\(issue.number) (\(assignees.count) assignee(s))")
        } catch {
            AppLogger.shared.error("Failed to assign issue #\(issue.number): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    /// Clones an issue via the API and immediately adds the copy to the local cache.
    func cloneIssue(_ issue: Issue) async {
        do {
            let cloned = try await apiService.createIssue(
                repositoryId: issue.repository.id,
                title: issue.title + " copy",
                body: issue.body,
                labelIds: issue.labels.map { $0.id }
            )
            upsertIssueInCache(cloned)
            AppLogger.shared.info("Cloned issue #\(issue.number) (\(issue.repository.fullName)) to #\(cloned.number)")
        } catch {
            AppLogger.shared.error("Failed to clone issue #\(issue.number): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Batch Operations (queued)
    //
    // These enqueue one operation per issue onto the shared serial queue, so a batch action shows
    // up in the bottom progress bar ("Processing issue X of N …") and runs one item at a time.

    func enqueueBatchDelete(_ issues: [Issue]) {
        for issue in issues {
            taskQueue.enqueue(title: issue.title) { [weak self] in await self?.deleteIssue(issue) }
        }
    }

    func enqueueBatchClose(_ issues: [Issue]) {
        for issue in issues where issue.state == .open {
            taskQueue.enqueue(title: issue.title) { [weak self] in await self?.closeIssue(issue) }
        }
    }

    func enqueueBatchClone(_ issues: [Issue]) {
        for issue in issues {
            taskQueue.enqueue(title: issue.title) { [weak self] in await self?.cloneIssue(issue) }
        }
    }

    func enqueueBatchAssign(_ issues: [Issue], assignees: [User]) {
        for issue in issues {
            taskQueue.enqueue(title: issue.title) { [weak self] in await self?.assignIssue(issue, assignees: assignees) }
        }
    }

    // MARK: - Kanban

    /// Transient status message for the Kanban board (e.g. an issue leaving the filtered view).
    /// Auto-clears after a few seconds.
    @Published var kanbanToastMessage: String?

    private func showKanbanToast(_ message: String) {
        kanbanToastMessage = message
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if self?.kanbanToastMessage == message {
                self?.kanbanToastMessage = nil
            }
        }
    }

    /// Moves a single issue to a Kanban state (column) and sets its order key.
    ///
    /// The cache is updated **optimistically** so the card moves immediately; the GitHub API
    /// calls run afterwards and reconcile (or revert) in the background.
    func moveIssue(_ issue: Issue, to state: KanbanState, orderKey: String) async {
        let optimistic = makeOptimisticMove(issue, to: state, orderKey: orderKey)
        upsertIssueInCache(optimistic)
        if !filterOptions.matches(issue: optimistic, viewerLogin: viewerLogin) {
            showKanbanToast("#\(optimistic.number) → \(state.name) (hidden by current filter)")
        }
        // The API reconciliation runs on the shared serial queue so it's reflected in the
        // bottom progress bar and can't overlap with other background work.
        taskQueue.enqueue(title: issue.title) { [weak self] in
            await self?.performKanbanMove(issue, to: state, orderKey: orderKey, revertTo: issue)
        }
    }

    /// Moves several issues into a Kanban state, assigning the given consecutive order keys.
    /// All cards move optimistically first; the API work then reconciles in the background.
    func moveIssues(_ issues: [Issue], to state: KanbanState, orderKeys: [String]) async {
        var hidden = 0
        for (issue, key) in zip(issues, orderKeys) {
            let optimistic = makeOptimisticMove(issue, to: state, orderKey: key)
            upsertIssueInCache(optimistic)
            if !filterOptions.matches(issue: optimistic, viewerLogin: viewerLogin) {
                hidden += 1
            }
        }
        if hidden > 0 {
            showKanbanToast("\(hidden) issue\(hidden == 1 ? "" : "s") → \(state.name) (hidden by current filter)")
        }
        // Enqueue each reconciliation on the shared serial queue (drives the progress bar).
        for (issue, key) in zip(issues, orderKeys) {
            taskQueue.enqueue(title: issue.title) { [weak self] in
                await self?.performKanbanMove(issue, to: state, orderKey: key, revertTo: issue)
            }
        }
    }

    /// Builds a locally-updated copy of `issue` reflecting the move: managed Kanban labels swapped
    /// for the target's (unless it's the clutter-free default/closed state), the order marker set,
    /// and the open/closed state flipped to match the column. Used for the optimistic cache update;
    /// the real label IDs and body are reconciled once the API calls return.
    private func makeOptimisticMove(_ issue: Issue, to state: KanbanState, orderKey: String) -> Issue {
        let settings = KanbanSettingsService.shared
        let managed = settings.managedLabelNames
        var labels = issue.labels.filter { !managed.contains($0.name.lowercased()) }
        let isClutterFree = state.id == settings.defaultState.id || state.isClosed
        if !isClutterFree {
            labels.append(Label(
                id: "kanban-optimistic-\(state.id.uuidString)",
                name: Kanban.labelName(for: state),
                color: settings.color(for: state)
            ))
        }
        return Issue(
            id: issue.id,
            number: issue.number,
            title: issue.title,
            body: KanbanOrderMarker.inject(orderKey, into: issue.body),
            state: state.isClosed ? .closed : .open,
            createdAt: issue.createdAt,
            updatedAt: issue.updatedAt,
            repository: issue.repository,
            labels: labels,
            assignees: issue.assignees,
            author: issue.author
        )
    }

    /// Applies a Kanban move to GitHub, then upserts the canonical issue. Reverts to `original` on
    /// failure. Only labels matching a *configured* state are touched; other users' `kanban-*`
    /// labels are left intact.
    private func performKanbanMove(_ issue: Issue, to state: KanbanState, orderKey: String, revertTo original: Issue) async {
        let settings = KanbanSettingsService.shared
        do {
            // Fetch the latest issue so we act on current labels/body (minimises clobber).
            let (current, _) = try await apiService.fetchIssueDetail(
                owner: issue.repository.owner.login,
                repo: issue.repository.name,
                number: issue.number
            )

            // 1. Remove the managed Kanban labels currently on the issue.
            let managed = settings.managedLabelNames
            let labelsToRemove = current.labels.filter { managed.contains($0.name.lowercased()) }
            if !labelsToRemove.isEmpty {
                try await apiService.removeLabelsFromIssue(issueId: issue.id, labelIds: labelsToRemove.map { $0.id })
            }

            // 2. Add the target label unless this is the clutter-free default or closed state.
            let isClutterFree = state.id == settings.defaultState.id || state.isClosed
            if !isClutterFree {
                let label = try await apiService.ensureLabel(
                    in: issue.repository,
                    name: Kanban.labelName(for: state),
                    color: settings.color(for: state)
                )
                try await apiService.addLabelsToIssue(issueId: issue.id, labelIds: [label.id])
            }

            // 3. Write the order key into the body marker, and flip open/closed to match the column.
            let newState: IssueState? = (state.isClosed != (issue.state == .closed))
                ? (state.isClosed ? .closed : .open)
                : nil
            let newBody = KanbanOrderMarker.inject(orderKey, into: current.body)
            _ = try await apiService.updateIssue(issueId: issue.id, title: nil, body: newBody, state: newState)

            // 4. Re-fetch the canonical issue and reconcile the cache (real label IDs, etc.).
            let (updated, _) = try await apiService.fetchIssueDetail(
                owner: issue.repository.owner.login,
                repo: issue.repository.name,
                number: issue.number
            )
            upsertIssueInCache(updated)
            AppLogger.shared.info("Moved issue #\(issue.number) (\(issue.repository.fullName)) to kanban state '\(state.name)'")
        } catch {
            AppLogger.shared.error("Failed to move issue #\(issue.number) to '\(state.name)': \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            // Revert the optimistic change.
            upsertIssueInCache(original)
        }
    }

    // MARK: - Issue Labels

    /// Fetches the labels a user can apply to issues in `repository` (Kanban labels excluded),
    /// sorted by name.
    func fetchEditableLabels(for repository: Repository) async throws -> [Label] {
        let all = try await apiService.fetchAllRepositoryLabels(
            owner: repository.owner.login,
            repo: repository.name
        )
        return Kanban.visibleLabels(all)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Creates a new label in `repository`.
    func createLabel(in repository: Repository, name: String, color: String) async throws -> Label {
        try await apiService.createLabel(repositoryId: repository.id, name: name, color: color)
    }

    /// Makes the issue's editable labels exactly `selected`, then updates the local cache.
    /// Existing Kanban labels are left untouched.
    func applyLabels(_ selected: [Label], to issue: Issue) async throws {
        let changes = LabelSelection.changes(current: issue.labels, selectedIds: Set(selected.map(\.id)))
        guard !changes.add.isEmpty || !changes.remove.isEmpty else { return }

        if !changes.add.isEmpty {
            try await apiService.addLabelsToIssue(issueId: issue.id, labelIds: changes.add)
        }
        if !changes.remove.isEmpty {
            try await apiService.removeLabelsFromIssue(issueId: issue.id, labelIds: changes.remove)
        }

        // Pick up the server's `updatedAt`, but always use the labels we just applied — GitHub's
        // read-after-write can briefly return the old set.
        var base = issue
        if let (refreshed, _) = try? await apiService.fetchIssueDetail(
            owner: issue.repository.owner.login,
            repo: issue.repository.name,
            number: issue.number
        ) {
            base = refreshed
        }
        let updated = Issue(
            id: base.id,
            number: base.number,
            title: base.title,
            body: base.body,
            state: base.state,
            createdAt: base.createdAt,
            updatedAt: base.updatedAt,
            repository: base.repository,
            labels: LabelSelection.resulting(current: issue.labels, selected: selected),
            assignees: base.assignees,
            author: base.author
        )
        upsertIssueInCache(updated)
        AppLogger.shared.info("Updated labels for issue #\(issue.number) (+\(changes.add.count) / -\(changes.remove.count))")
    }

    // MARK: - Cross-Repository Transfer

    /// Fetches all repositories the user can transfer issues into.
    /// Falls back to the repositories already represented in the issues list on failure.
    func fetchSelectableRepositories() async -> [Repository] {
        do {
            return try await apiService.fetchAllRepositories()
        } catch {
            errorMessage = error.localizedDescription
            return availableRepositories
        }
    }

    /// Copies the given issues into the destination repository, updating the cache for each success.
    func copyIssues(_ issues: [Issue], to destination: Repository, progress: ((Int, Int) -> Void)? = nil) async -> TransferResult {
        await copyIssues(issues, to: [destination], progress: progress)
    }

    /// Copies the given issues into **each** destination repository, updating the cache for every
    /// success. Each per-issue copy runs on the shared serial queue (so it appears in the progress
    /// bar). Progress is reported over the full `issues.count * destinations.count` work. Failure
    /// messages are prefixed with the destination so the summary is unambiguous across repos.
    func copyIssues(_ issues: [Issue], to destinations: [Repository], progress: ((Int, Int) -> Void)? = nil) async -> TransferResult {
        let names = destinations.map { $0.fullName }.joined(separator: ", ")
        AppLogger.shared.info("Copying \(issues.count) issue(s) to \(destinations.count) repo(s): \(names)")

        // Build one queued operation per (destination, issue); results come back in this order.
        var plan: [(issue: Issue, destination: Repository)] = []
        for destination in destinations {
            for issue in issues { plan.append((issue, destination)) }
        }
        let items: [(title: String, work: @MainActor () async -> Result<Issue, Error>)] = plan.map { entry in
            (title: entry.issue.title, work: {
                do { return .success(try await self.apiService.copyIssue(entry.issue, to: entry.destination)) }
                catch { return .failure(error) }
            })
        }
        let outcomes = await taskQueue.enqueueAll(items, onItemComplete: progress)

        var succeeded = 0
        var failures: [(issue: Issue, message: String)] = []
        for (entry, outcome) in zip(plan, outcomes) {
            switch outcome {
            case .success(let newIssue):
                upsertIssueInCache(newIssue)
                succeeded += 1
                AppLogger.shared.info("Copied issue #\(entry.issue.number) (\(entry.issue.repository.fullName)) to \(entry.destination.fullName) #\(newIssue.number)")
            case .failure(let error):
                AppLogger.shared.error("Failed to copy issue #\(entry.issue.number) to \(entry.destination.fullName): \(error.localizedDescription)")
                failures.append((entry.issue, "\(entry.destination.fullName): \(error.localizedDescription)"))
            }
        }
        AppLogger.shared.info("Copy finished: \(succeeded) succeeded, \(failures.count) failed")
        return TransferResult(succeeded: succeeded, failures: failures)
    }

    /// Moves the given issues into the destination repository (preserving timestamps), updating
    /// the cache for each success: the new issue is inserted and the original removed.
    func moveIssues(_ issues: [Issue], to destination: Repository, progress: ((Int, Int) -> Void)? = nil) async -> TransferResult {
        AppLogger.shared.info("Moving \(issues.count) issue(s) to \(destination.fullName)")

        // Each move runs on the shared serial queue (so it appears in the progress bar); the whole
        // batch is enqueued up front so the bar reads "X of N".
        let items: [(title: String, work: @MainActor () async -> Result<Issue, Error>)] = issues.map { issue in
            (title: issue.title, work: {
                do { return .success(try await self.apiService.moveIssue(issue, to: destination)) }
                catch { return .failure(error) }
            })
        }
        let outcomes = await taskQueue.enqueueAll(items, onItemComplete: progress)

        var succeeded = 0
        var failures: [(issue: Issue, message: String)] = []
        for (issue, outcome) in zip(issues, outcomes) {
            switch outcome {
            case .success(let newIssue):
                removeIssueFromCache(id: issue.id)
                upsertIssueInCache(newIssue)
                succeeded += 1
                AppLogger.shared.info("Moved issue #\(issue.number) (\(issue.repository.fullName)) to \(destination.fullName) #\(newIssue.number)")
            case .failure(let error):
                AppLogger.shared.error("Failed to move issue #\(issue.number) to \(destination.fullName): \(error.localizedDescription)")
                failures.append((issue, error.localizedDescription))
            }
        }
        AppLogger.shared.info("Move finished: \(succeeded) succeeded, \(failures.count) failed")
        return TransferResult(succeeded: succeeded, failures: failures)
    }

    // MARK: - Filters

    /// Applies filters and sorting to issues
    private static func applyFiltersAndSort(filterOptions: FilterOptions, to issues: [Issue], pinnedIDs: Set<String>, viewerLogin: String?) -> [Issue] {
        // Filter issues
        let filtered = issues.filter { filterOptions.matches(issue: $0, viewerLogin: viewerLogin) }

        // Sort issues
        let sorted = filterOptions.sortOption.sort(filtered)

        // Separate pinned and unpinned
        let pinned = sorted.filter { pinnedIDs.contains($0.id) }
        let unpinned = sorted.filter { !pinnedIDs.contains($0.id) }

        // Return pinned first, then unpinned
        return pinned + unpinned
    }

    /// Toggles the pinned state of an issue
    func togglePin(for issueID: String) {
        pinningService.togglePin(issueID)
        pinnedIssueIDs = pinningService.getPinnedIssues()
    }

    /// Checks if an issue is pinned
    func isPinned(_ issueID: String) -> Bool {
        return pinnedIssueIDs.contains(issueID)
    }

    /// Gets all unique repositories from the issues list
    var availableRepositories: [Repository] {
        let repos = allIssues.map { $0.repository }
        let uniqueRepos = Dictionary(grouping: repos, by: { $0.id })
            .compactMap { $0.value.first }
        return uniqueRepos.sortedByName()
    }

    /// Updates the state filter (client-side; no API call needed)
    func setStateFilter(_ filter: IssueStateFilter) {
        filterOptions.stateFilter = filter
    }

    /// Updates the visibility filter (client-side; no API call needed)
    func setVisibilityFilter(_ filter: VisibilityFilter) {
        filterOptions.visibilityFilter = filter
    }

    /// Updates the involvement filter
    func setInvolvementFilter(_ filter: InvolvementFilter) {
        var options = filterOptions
        options.involvementFilter = filter
        filterOptions = options
    }

    /// Updates the sort option
    func setSortOption(_ option: SortOption) {
        var options = filterOptions
        options.sortOption = option
        filterOptions = options
    }

    /// Updates the search text
    func setSearchText(_ text: String) {
        var options = filterOptions
        options.searchText = text
        filterOptions = options
    }

    /// Toggles repository selection
    func toggleRepository(_ repositoryID: String) {
        var options = filterOptions
        if options.selectedRepositories.contains(repositoryID) {
            options.selectedRepositories.remove(repositoryID)
        } else {
            options.selectedRepositories.insert(repositoryID)
        }
        filterOptions = options
    }

    /// Clears all repository filters
    func clearRepositoryFilter() {
        var options = filterOptions
        options.selectedRepositories.removeAll()
        filterOptions = options
    }

    /// Gets unique labels (by lowercased name) from currently displayed issues (excluding label filter)
    var availableLabels: [Label] {
        let issuesInScope = allIssues.filter { filterOptions.matchesExcludingLabels(issue: $0, viewerLogin: viewerLogin) }
        var seen = Set<String>()
        var labels: [Label] = []
        for issue in issuesInScope {
            for label in issue.labels {
                // Hide Kanban state labels from the filter UI.
                if Kanban.isKanbanLabel(label.name) { continue }
                let key = label.name.lowercased()
                if seen.insert(key).inserted {
                    labels.append(Label(id: key, name: key, color: label.color))
                }
            }
        }
        return labels.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Toggles label selection (by lowercased name)
    func toggleLabel(_ labelName: String) {
        var options = filterOptions
        let key = labelName.lowercased()
        if options.selectedLabels.contains(key) {
            options.selectedLabels.remove(key)
        } else {
            options.selectedLabels.insert(key)
        }
        filterOptions = options
    }

    /// Clears all label filters
    func clearLabelFilter() {
        var options = filterOptions
        options.selectedLabels.removeAll()
        filterOptions = options
    }
}

/// Summary of a copy/move operation across one or more issues.
struct TransferResult {
    let succeeded: Int
    let failures: [(issue: Issue, message: String)]

    var total: Int { succeeded + failures.count }
}
