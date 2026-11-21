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
    /// Filtered and sorted by the selected Sort option. Pin state is **not** applied: the Kanban
    /// board uses this directly.
    @Published var filteredIssues: [Issue] = []
    /// `filteredIssues` with pinned issues moved to the front — what the issue list displays.
    @Published var listIssues: [Issue] = []
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var filterOptions = FilterOptions()
    @Published var pinnedIssueIDs: Set<String> = []
    @Published var viewerLogin: String?

    private let apiService: GitHubAPIService
    private let cacheStore: IssueCacheStore
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

    // Sync bookkeeping (issue #109): decides full vs incremental syncs and is persisted with the
    // on-disk cache so it survives a relaunch.
    /// When the last *complete* fetch started.
    private var lastFullSyncAt: Date?
    /// When the most recent fetch (full or incremental) started.
    private var lastSyncAt: Date?
    /// The cache store's generation when this view model started (or last reset); saves made under
    /// an older generation (after a sign-out / cache clear) are dropped.
    private var cacheGeneration: Int

    init(accessToken: String, cacheStore injectedCacheStore: IssueCacheStore? = nil) {
        let cacheStore = injectedCacheStore ?? IssueCacheStore.shared
        self.apiService = GitHubAPIService(accessToken: accessToken)
        self.cacheStore = cacheStore
        self.cacheGeneration = cacheStore.generation
        self.pinningService = PinningService()
        self.pinnedIssueIDs = pinningService.getPinnedIssues()

        // Restore saved filter state
        if let savedFilterOptions = appStateService.loadFilterState() {
            self.filterOptions = savedFilterOptions
        }

        // Observe filter changes and refilter
        Publishers.CombineLatest4($filterOptions, $allIssues, $pinnedIssueIDs, $viewerLogin)
            .map { filterOptions, allIssues, _, viewerLogin in
                Self.applyFiltersAndSort(filterOptions: filterOptions, to: allIssues, viewerLogin: viewerLogin)
            }
            .assign(to: &$filteredIssues)

        // The issue list shows pinned issues first; the Kanban board ignores pins.
        Publishers.CombineLatest($filteredIssues, $pinnedIssueIDs)
            .map { filtered, pinnedIDs in Self.pinnedFirst(filtered, pinnedIDs: pinnedIDs) }
            .assign(to: &$listIssues)

        // Save filter state whenever it changes
        $filterOptions
            .dropFirst() // Skip initial value
            .sink { [weak self] newFilterOptions in
                self?.appStateService.saveFilterState(newFilterOptions)
            }
            .store(in: &cancellables)

        // Persist the issue list shortly after it settles, so the next launch can show it at once.
        $allIssues
            .dropFirst()
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveCacheIfIdle() }
            .store(in: &cancellables)

        // "Clear Cache & Reload" in Settings.
        NotificationCenter.default.publisher(for: .issueCacheCleared)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.resetAfterCacheCleared() }
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

        let loadTimer = PerfTimer()
        do {
            // Fetch all issues regardless of state/visibility — filtering is done client-side.
            // On a cold start (empty list) results are published page by page so the open issues
            // appear after the first request instead of after every closed issue has downloaded.
            let count = try await fetchAndApplyIssues(progressive: allIssues.isEmpty)
            AppLogger.shared.info("Loaded \(count) issues from GitHub")
            PerfTimer.log("loadIssues TOTAL", loadTimer, "issues=\(count)")
        } catch {
            AppLogger.shared.error("Failed to load issues: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
        }

        isLoading = false
        isRefreshing = false
    }

    // MARK: - Launch, cache and incremental sync (issue #109)

    /// Launch entry point. Shows the cached issue list immediately (when there is one for this
    /// account), then brings it up to date: a small incremental request if the cache is recent, or
    /// a full reload if it is old, missing, or was fetched under different settings. With no cache
    /// this is just `loadIssues()`.
    func loadInitialIssues() async {
        guard let snapshot = await restoreFromCache() else {
            await loadIssues()
            return
        }

        // Confirm the cache belongs to the signed-in account, concurrently with the refresh.
        let verification = Task { try await self.apiService.fetchViewerLogin() }

        switch SyncPlanner.mode(lastFullSyncAt: lastFullSyncAt, lastSyncAt: lastSyncAt) {
        case .full:
            await loadIssues()
        case .incremental(let since):
            await refreshIncrementally(since: since, label: "launch incremental sync")
        }

        // Different account than the cache was written for: throw it all away and start fresh.
        if let login = try? await verification.value, login != snapshot.userLogin {
            AppLogger.shared.warning("Issue cache belonged to another account; discarding")
            cacheStore.clear()
            cacheGeneration = cacheStore.generation
            clearInMemoryIssues()
            viewerLogin = login
            await loadIssues()
        }
    }

    /// User-initiated refresh (toolbar button, ⌘R). Follows the same rule as the background sync:
    /// one small incremental request when the last full sync is recent, a full reload otherwise.
    /// A deletion made elsewhere therefore shows up at the next full reconcile (within 10 minutes)
    /// or immediately via `loadIssues()` ("Reload All Issues", ⇧⌘R).
    func refreshIssues() async {
        guard !isLoading, !isRefreshing else { return }
        guard !allIssues.isEmpty else {
            await loadIssues()
            return
        }
        switch SyncPlanner.mode(lastFullSyncAt: lastFullSyncAt, lastSyncAt: lastSyncAt) {
        case .full:
            await loadIssues()
        case .incremental(let since):
            await refreshIncrementally(since: since, label: "manual incremental refresh")
        }
    }

    /// Runs one incremental sync with the toolbar spinner showing, surfacing any error.
    private func refreshIncrementally(since: Date, label: String) async {
        isRefreshing = true
        errorMessage = nil
        let timer = PerfTimer()
        do {
            let changed = try await fetchAndApplyIncremental(since: since)
            PerfTimer.log(label, timer, "changed=\(changed)")
        } catch {
            AppLogger.shared.error("\(label) failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isRefreshing = false
    }

    /// Publishes the on-disk snapshot, if any. Returns it when the list was restored.
    private func restoreFromCache() async -> CachedIssueSnapshot? {
        guard allIssues.isEmpty, let snapshot = await cacheStore.load() else { return nil }
        // Something else may have populated the list while the file was being read.
        guard allIssues.isEmpty else { return nil }

        viewerLogin = snapshot.userLogin
        allIssues = snapshot.issues
        lastSyncAt = snapshot.lastSyncAt
        // A cache built under a different read-only setting may be missing (or wrongly contain)
        // archived-repo issues; leaving the full-sync time unset forces a full reload.
        lastFullSyncAt = snapshot.allowReadOnly == AppStateService.allowReadOnlyRepoAccess
            ? snapshot.lastFullSyncAt
            : nil
        AppLogger.shared.info("Restored \(snapshot.issues.count) issues from cache")
        return snapshot
    }

    /// Writes the current list to disk, unless a load or background mutation is still in flight
    /// (the list may then be partial or hold an unconfirmed optimistic edit) or no full sync has
    /// completed yet.
    private func saveCacheIfIdle() {
        guard !isLoading, !isRefreshing, !taskQueue.isProcessing,
              !allIssues.isEmpty,
              let login = viewerLogin,
              let lastFullSyncAt, let lastSyncAt else { return }

        cacheStore.save(
            CachedIssueSnapshot(
                schemaVersion: IssueCacheStore.schemaVersion,
                userLogin: login,
                savedAt: Date(),
                lastFullSyncAt: lastFullSyncAt,
                lastSyncAt: lastSyncAt,
                allowReadOnly: AppStateService.allowReadOnlyRepoAccess,
                issues: allIssues
            ),
            generation: cacheGeneration
        )
    }

    /// Drops the in-memory list and sync state (after the cache was cleared or turned out to belong
    /// to another account).
    private func clearInMemoryIssues() {
        allIssues = []
        pendingDeletions = []
        pendingInsertions = []
        pendingUpdates = [:]
        lastFullSyncAt = nil
        lastSyncAt = nil
    }

    private func resetAfterCacheCleared() async {
        cacheGeneration = cacheStore.generation
        clearInMemoryIssues()
        await loadIssues()
    }

    /// Fetches only issues updated since `since` and merges them into the list. Returns how many
    /// changed issues came back.
    @discardableResult
    private func fetchAndApplyIncremental(since: Date) async throws -> Int {
        fetchSequence += 1
        let sequence = fetchSequence
        let startedAt = Date()
        let timer = PerfTimer()

        if viewerLogin == nil {
            viewerLogin = try await apiService.fetchViewerLogin()
        }

        let accumulator = IssueFetchAccumulator()
        try await apiService.fetchIssuePages(state: nil, updatedSince: since) { accumulator.add($0) }
        let changed = accumulator.snapshot

        guard sequence > lastAppliedFetchSequence else { return changed.count }
        lastAppliedFetchSequence = sequence

        if !changed.isEmpty {
            allIssues = IssueSyncMerger.applyIncremental(
                existing: allIssues,
                changed: changed,
                pendingUpdates: &pendingUpdates,
                pendingDeletions: pendingDeletions,
                pendingInsertions: &pendingInsertions,
                fetchStartedAt: startedAt
            )
        }
        lastSyncAt = startedAt
        PerfTimer.log("incremental sync", timer, "since=\(IssueSearchQuery.timestamp(since)) changed=\(changed.count) total=\(allIssues.count)")
        return changed.count
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
            switch SyncPlanner.mode(lastFullSyncAt: lastFullSyncAt, lastSyncAt: lastSyncAt) {
            case .full:
                _ = try await fetchAndApplyIssues(progressive: false)
            case .incremental(let since):
                try await fetchAndApplyIncremental(since: since)
            }
        } catch {
            // Silent sync — don't surface transient errors
        }
    }

    /// Fetches all issues and merges them into the cache. Returns the number of issues fetched.
    ///
    /// Open and closed issues are fetched as two **concurrent** paged searches (cursor paging within
    /// one search is serial, but two independent searches overlap), and the viewer login is fetched
    /// alongside them rather than before them. When `progressive` is set, the list is published
    /// after every page so the UI fills in as results arrive; otherwise (a refresh over existing
    /// data) the list is swapped once at the end so rows never disappear mid-refresh.
    ///
    /// The fetch is stamped with its start time and a sequence number so the merge can tell
    /// whether the response predates a local edit (see `IssueSyncMerger`), and so a response that
    /// arrives after a newer fetch has already been applied is discarded rather than rolling the
    /// list back.
    private func fetchAndApplyIssues(progressive: Bool) async throws -> Int {
        fetchSequence += 1
        let sequence = fetchSequence
        let startedAt = Date()
        let fetchTimer = PerfTimer()

        // The viewer login only feeds the client-side involvement filter; fetch it concurrently.
        let viewerTask: Task<String, Error>? = viewerLogin == nil
            ? Task { try await self.apiService.fetchViewerLogin() }
            : nil

        let accumulator = IssueFetchAccumulator()

        /// Handles one arriving page. Runs on the main actor (as does everything in this type).
        func handle(page: [Issue]) async {
            accumulator.add(page)
            guard progressive, sequence == fetchSequence, sequence > lastAppliedFetchSequence else { return }

            // The involvement filter needs the login; it normally lands well before the first page.
            if viewerLogin == nil, let viewerTask {
                viewerLogin = try? await viewerTask.value
            }

            let publishTimer = PerfTimer()
            publish(accumulator.snapshot, fetchStartedAt: startedAt, isComplete: false)
            PerfTimer.log("progressive publish", publishTimer, "issues=\(accumulator.count)", slowAfterMs: 20)

            // Drop the full-screen spinner as soon as there is something to show; the toolbar
            // refresh indicator takes over while the remaining pages download.
            if isLoading, !allIssues.isEmpty {
                isLoading = false
                isRefreshing = true
                PerfTimer.log("first results visible", fetchTimer, "issues=\(allIssues.count)")
            }
        }

        async let openCount = apiService.fetchIssuePages(state: .open) { await handle(page: $0) }
        async let closedCount = apiService.fetchIssuePages(state: .closed) { await handle(page: $0) }
        _ = try await (openCount, closedCount)

        if let viewerTask {
            viewerLogin = try await viewerTask.value
        }

        let issues = accumulator.snapshot
        guard sequence > lastAppliedFetchSequence else { return issues.count }
        lastAppliedFetchSequence = sequence
        // Time the merge + publish. `allIssues` publishes synchronously into the filter/sort
        // pipeline, so this includes `applyFiltersAndSort` on the main thread.
        let applyTimer = PerfTimer()
        publish(issues, fetchStartedAt: startedAt, isComplete: true)
        lastFullSyncAt = startedAt
        lastSyncAt = startedAt
        PerfTimer.log("applyIssuesFromSync (merge+filter+sort)", applyTimer, "issues=\(issues.count)")
        PerfTimer.log("fetchAndApplyIssues TOTAL", fetchTimer, "issues=\(issues.count) progressive=\(progressive)")
        return issues.count
    }

    /// Publishes `issues` to `allIssues`, merged with any pending local mutations that may have
    /// raced ahead of the in-flight fetch (see `IssueSyncMerger.reconcile`).
    private func publish(_ issues: [Issue], fetchStartedAt: Date, isComplete: Bool) {
        allIssues = IssueSyncMerger.reconcile(
            incoming: issues,
            pendingUpdates: &pendingUpdates,
            pendingDeletions: &pendingDeletions,
            pendingInsertions: &pendingInsertions,
            fetchStartedAt: fetchStartedAt,
            isComplete: isComplete
        )
    }

    // MARK: - Cache Mutations

    /// Inserts or updates an issue in the local cache without a full reload.
    /// If the issue already exists it is updated in place; otherwise it is inserted at the front.
    func upsertIssueInCache(_ issue: Issue) {
        // Includes the synchronous re-filter/re-sort triggered by the `allIssues` change.
        let upsertTimer = PerfTimer()
        defer { PerfTimer.log("upsertIssueInCache", upsertTimer, "issues=\(allIssues.count)", slowAfterMs: 20) }

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

    /// Closes an issue via the API and immediately updates the local cache. Any managed Kanban
    /// label is removed in the same request so the closed issue lands in the Done column instead
    /// of lingering in its old column; other users' `kanban-*` labels (not part of this config)
    /// are left intact, mirroring `performKanbanMove`.
    func closeIssue(_ issue: Issue) async {
        do {
            let updatedIssue = try await apiService.closeIssue(
                issue,
                managedLabelNames: KanbanSettingsService.shared.managedLabelNames
            )
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

    /// Moves a single issue to a Kanban state (column) and sets its order key. A `nil` key leaves
    /// the issue's existing order marker untouched (used when "Kanban Dragged" is off).
    ///
    /// The cache is updated **optimistically** so the card moves immediately; the GitHub API
    /// calls run afterwards and reconcile (or revert) in the background.
    func moveIssue(_ issue: Issue, to state: KanbanState, orderKey: String?) async {
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

    /// Moves several issues into a Kanban state, assigning the given order keys (`nil` entries leave
    /// that issue's marker untouched). Issues already in `state` are simply re-keyed.
    /// All cards move optimistically first; the API work then reconciles in the background.
    func moveIssues(_ issues: [Issue], to state: KanbanState, orderKeys: [String?]) async {
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
    private func makeOptimisticMove(_ issue: Issue, to state: KanbanState, orderKey: String?) -> Issue {
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
            body: orderKey.map { KanbanOrderMarker.inject($0, into: issue.body) } ?? issue.body,
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
    private func performKanbanMove(_ issue: Issue, to state: KanbanState, orderKey: String?, revertTo original: Issue) async {
        let settings = KanbanSettingsService.shared
        let moveTimer = PerfTimer()
        var step = PerfTimer()
        var steps: [String] = []
        func lap(_ name: String) {
            steps.append("\(name)=\(step.elapsedString)ms")
            step = PerfTimer()
        }

        /// One read-modify-write: read the issue's current labels/body, then write the new labels,
        /// body marker and open/closed state in a **single** `updateIssue` mutation. Each GitHub
        /// mutation costs ~1–1.5 s, so this replaced a remove-labels / add-labels / update chain
        /// (plus a second full re-read; the mutation response already is the canonical issue).
        func attempt() async throws -> Issue {
            // Read the latest issue so we act on current labels/body (minimises clobber). Uses the
            // lightweight query: all labels (the replacement set must be complete), no comments.
            let current = try await apiService.fetchIssueForUpdate(
                owner: issue.repository.owner.login,
                repo: issue.repository.name,
                number: issue.number
            )
            lap("read")

            // The target label, unless this is the clutter-free default or closed state. Label ids
            // come from a per-repository cache, so only the first move in a repo pays for a lookup.
            let isClutterFree = state.id == settings.defaultState.id || state.isClosed
            var target: Label?
            if !isClutterFree {
                target = try await apiService.ensureLabel(
                    in: issue.repository,
                    name: Kanban.labelName(for: state),
                    color: settings.color(for: state)
                )
                lap("ensureLabel")
            }

            // Managed Kanban labels are swapped for the target; other users' labels are kept. `nil`
            // means the set is unchanged (e.g. reordering within a column), so labels are not sent.
            let labelIds = KanbanMovePlanner.labelUpdate(
                currentLabels: current.labels,
                managedLabelNames: settings.managedLabelNames,
                adding: target
            )

            // Write the order key into the body marker, and flip open/closed to match the column.
            let newState: IssueState? = (state.isClosed != (current.state == .closed))
                ? (state.isClosed ? .closed : .open)
                : nil
            // With no key (Kanban Dragged off) the body is left alone, so any stored order survives.
            let newBody = orderKey.map { KanbanOrderMarker.inject($0, into: current.body) }
            let updated = try await apiService.updateIssue(
                issueId: issue.id, title: nil, body: newBody, state: newState, labelIds: labelIds
            )
            lap("updateIssue")
            return updated
        }

        do {
            let updated: Issue
            do {
                updated = try await attempt()
            } catch GraphQLError.notFound {
                // The issue was deleted elsewhere: nothing to move or retry. Drop the stale card.
                PerfTimer.log("kanbanMove NOT FOUND", moveTimer, steps.joined(separator: " "))
                AppLogger.shared.info("Issue #\(issue.number) no longer exists on GitHub; removing it from the list")
                removeIssueFromCache(id: issue.id)
                errorMessage = "Issue #\(issue.number) no longer exists on GitHub, so it was removed from the list."
                return
            } catch {
                // A cached label id may be stale (label deleted/renamed on github.com). Drop the
                // repository's cached labels and retry once with a fresh lookup; if nothing was
                // cached the failure is genuine.
                guard apiService.invalidateLabelCache(for: issue.repository) else { throw error }
                AppLogger.shared.warning("Kanban move of #\(issue.number) failed (\(error.localizedDescription)); retrying with fresh labels")
                steps.append("retry")
                step = PerfTimer()
                updated = try await attempt()
            }
            upsertIssueInCache(updated)
            lap("upsert")
            PerfTimer.log("kanbanMove TOTAL", moveTimer, steps.joined(separator: " "))
            AppLogger.shared.info("Moved issue #\(issue.number) (\(issue.repository.fullName)) to kanban state '\(state.name)'")
        } catch {
            PerfTimer.log("kanbanMove FAILED", moveTimer, steps.joined(separator: " "))
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

    /// Creates each label in its repository and returns the created labels keyed by repository ID,
    /// plus a message per failure. Used before applying labels that some repositories lack.
    func createLabels(_ creations: [RepoLabelCreation]) async -> (created: [String: [Label]], failures: [String]) {
        var created: [String: [Label]] = [:]
        var failures: [String] = []
        for creation in creations {
            do {
                let label = try await createLabel(in: creation.repository, name: creation.name, color: creation.color)
                created[creation.repository.id, default: []].append(label)
            } catch {
                AppLogger.shared.error("Failed to create label '\(creation.name)' in \(creation.repository.fullName): \(error.localizedDescription)")
                failures.append("\(creation.repository.fullName): \(error.localizedDescription)")
            }
        }
        return (created, failures)
    }

    /// Applies one issue's planned label change (adds `change.add`, removes `change.remove`) using
    /// the repository labels in `repoLabels`, then updates the local cache. Kanban labels are left
    /// untouched. With `refreshDetail`, also fetches the issue to pick up the server `updatedAt`.
    func applyLabelChange(_ change: IssueLabelChange, repoLabels: [String: [Label]], refreshDetail: Bool) async throws {
        let issue = change.issue
        let resolved = BatchLabelSelection.resolve(change, repoLabels: repoLabels)
        guard !resolved.add.isEmpty || !resolved.removeIDs.isEmpty else { return }

        if !resolved.add.isEmpty {
            try await apiService.addLabelsToIssue(issueId: issue.id, labelIds: resolved.add.map(\.id))
        }
        if !resolved.removeIDs.isEmpty {
            try await apiService.removeLabelsFromIssue(issueId: issue.id, labelIds: resolved.removeIDs)
        }

        // Always use the labels we just applied — GitHub's read-after-write can briefly return the
        // old set. The detail fetch is only to pick up `updatedAt`, so batches skip it.
        var base = issue
        if refreshDetail,
           let (refreshed, _) = try? await apiService.fetchIssueDetail(
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
            labels: BatchLabelSelection.resultingLabels(current: issue.labels, add: resolved.add, removeIDs: resolved.removeIDs),
            assignees: base.assignees,
            author: base.author
        )
        upsertIssueInCache(updated)
        AppLogger.shared.info("Updated labels for issue #\(issue.number) (+\(resolved.add.count) / -\(resolved.removeIDs.count))")
    }

    /// Queues one label update per issue (shown in the bottom progress bar). A failure is reported
    /// via `errorMessage` and doesn't stop the remaining issues.
    func enqueueBatchLabels(_ changes: [IssueLabelChange], repoLabels: [String: [Label]]) {
        for change in changes {
            taskQueue.enqueue(title: change.issue.title) { [weak self] in
                do {
                    try await self?.applyLabelChange(change, repoLabels: repoLabels, refreshDetail: false)
                } catch {
                    AppLogger.shared.error("Failed to update labels for issue #\(change.issue.number): \(error.localizedDescription)")
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
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

    /// Applies filters and sorting to issues. Pinned issues are not treated specially here.
    private static func applyFiltersAndSort(filterOptions: FilterOptions, to issues: [Issue], viewerLogin: String?) -> [Issue] {
        let timer = PerfTimer()
        defer { PerfTimer.log("applyFiltersAndSort", timer, "in=\(issues.count)", slowAfterMs: 10) }

        // Filter issues
        let filtered = issues.filter { filterOptions.matches(issue: $0, viewerLogin: viewerLogin) }

        return filterOptions.sortOption.sort(filtered)
    }

    /// `issues` with the pinned ones first; the relative order within each group is preserved.
    static func pinnedFirst(_ issues: [Issue], pinnedIDs: Set<String>) -> [Issue] {
        guard !pinnedIDs.isEmpty else { return issues }
        let pinned = issues.filter { pinnedIDs.contains($0.id) }
        let unpinned = issues.filter { !pinnedIDs.contains($0.id) }
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

    /// Turns the Kanban board's "dragged order" on or off (see `FilterOptions.kanbanDragged`).
    func setKanbanDragged(_ enabled: Bool) {
        var options = filterOptions
        options.kanbanDragged = enabled
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
