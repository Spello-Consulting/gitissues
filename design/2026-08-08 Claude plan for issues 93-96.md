# Implementation Plan — Issues #93, #94, #95, #96

## Context

Four GitHub issues target the GitIssues macOS app (SwiftUI). They range from a settings/permissions feature to a UX polish item:

- **#93** — Archived/read-only repos reject edits, so their issues silently fail to update. Hide them by default; when shown, disable all mutating operations and mark them.
- **#94** — "Copy to repository" only allows one destination; users want to copy an issue to several repos at once.
- **#95** — Closing an issue directly (context menu / "Save and Close") leaves its `kanban-<Status>` label in place, so a Closed issue shows in the wrong Kanban column instead of Done.
- **#96** — Async API changes (Kanban drags, batch ops, cross-repo copy/move) process in the background with the display updating piecemeal; there's no indication of queued work. Add a footer progress bar.

**Decisions from the user:**
- #93 read-only = **archived OR no write access** (repo `isArchived`, or `viewerPermission` not in ADMIN/MAINTAIN/WRITE).
- #94 multi-select applies to **Copy only** (Move stays single-destination).
- #96 the footer bar reports on **Kanban + batch ops + cross-repo copy/move** via one shared serial queue.

All paths below are under `GitIssues/GitIssues/`.

---

## #93 — Hide read-only repos by default

**Surface read-only status on the model.** Currently `Repository` (`Models/Repository.swift`) decodes only `id, name, owner, isPrivate`; `isArchived`/`hasIssuesEnabled` are fetched only by `repositoriesQuery` and dropped. Changes:

- Add `isArchived: Bool` and `viewerPermission: String?` to `Repository`, plus a computed `var isReadOnly: Bool { isArchived || !["ADMIN","MAINTAIN","WRITE"].contains(viewerPermission ?? "") }`. Give the new fields defaulted decoding so cached/older payloads still decode.
- In `Networking/GraphQLQueries.swift`, add `isArchived` and `viewerPermission` to **every** repository fragment that feeds an `Issue` or `Repository` we display: the issue-search embedded `RepositoryNode`, `IssueDetailResponse.RepositoryNode`, the create/update mutation `RepositoryNode`s, and `RepositoriesResponse.RepositoryNode`. Carry the two fields through each `toRepository()`.

**New setting.** Follow the existing toggle pattern (static key on a service + `@AppStorage` in the view + static reader):
- Add key `allowReadOnlyRepoAccessKey = "allowReadOnlyRepoAccess"` and a static reader `allowReadOnlyRepoAccess` (default **false**) to `Services/AppStateService.swift`.
- In `Views/Settings/SettingsView.swift` GitHub Access section (after the private-repo toggle, ~line 100), add `Toggle("Allow read-only repository access", isOn:)` bound via `@AppStorage(AppStateService.allowReadOnlyRepoAccessKey)`, with a caption. On change, trigger a list refresh.

**Exclude when disabled.**
- Server-side for the issue fetch: in `GitHubAPIService.fetchIssues` (~line 50), append `"archived:false"` to `queryParts` when the setting is off. This is GitHub search's native qualifier and truly excludes archived repos.
- Client-side catch-all (covers no-write-access repos search can't express): add an `allowReadOnly` flag to `FilterOptions` and, in `matches()` (`Models/FilterOptions.swift`), return `false` when `!allowReadOnly && issue.repository.isReadOnly`. Set the flag from the setting where `filterOptions` is built in `IssuesListViewModel`.
- Repo pickers (`fetchSelectableRepositories`/`fetchRepositories`) already drop archived via `acceptsNewIssues`; also filter out non-writable when the setting is off.

**When read-only issues ARE shown (setting on): disable ops + label.**
- `Views/IssuesList/IssueContextMenu.swift`: when `issue.repository.isReadOnly` (single) — or any selected issue is read-only (batch) — render the mutating items `.disabled(true)` (Edit, Clone, Assign, Copy/Move, Close/Reopen, Delete).
- `Views/IssueDetail/IssueDetailView.swift` `IssueHeaderView` (buttons ~lines 282–324): add `.disabled(issue.repository.isReadOnly)` to Edit, Assign, Pin, Delete.
- `Views/Kanban/KanbanBoardView.swift`: gate `.draggable(issue.id)` (line 120) on `!issue.repository.isReadOnly` so read-only cards can't be dragged.
- Append `" (read-only)"` after the repo name where `issue.repository.fullName` is shown: `IssueRow` (ContentView.swift ~line 571) and `KanbanCardView` (KanbanBoardView.swift ~line 263). Add a small helper (e.g. `Issue.repositoryDisplayName`) to avoid duplicating the ternary.

---

## #94 — Copy to multiple repositories (Copy only)

In `Views/IssuesList/TransferIssuesSheet.swift`:
- Replace `@State selectedRepo: Repository?` with `@State selectedRepos: [Repository] = []` (ordered). For `.copy`, `RepositoryRow` toggles membership (`isSelected: selectedRepos.contains(repo)`, `onToggle:` add/remove) — multi-select with checkmarks. For `.move`, keep radio behavior (selecting replaces, max one).
- Enable "Continue" when `!selectedRepos.isEmpty`. Update confirmation/summary copy to name all destinations (e.g. "Copy these 3 issues to 2 repositories?").
- `performTransfer()`: for `.copy`, loop destinations calling the existing `viewModel.copyIssues(issues, to: repo, progress:)` per repo, aggregating `TransferResult`s; total for progress = `issues.count * selectedRepos.count`. `.move` stays single destination.

`IssuesListViewModel.copyIssues` already handles one destination; multi-destination is orchestrated in the sheet (or add a thin `copyIssues(_:to destinations:[Repository])` wrapper on the view model that loops and aggregates — preferred so the progress/queue integration for #96 lives in the view model).

---

## #95 — Clear Kanban label when an issue is closed

When an issue is closed outside the board, its managed `kanban-<Status>` label must be removed so `KanbanSettingsService.state(for:)` resolves it to the closed/Done column.

- Extract a helper on `IssuesListViewModel`, e.g. `clearManagedKanbanLabels(on issue:) async`, mirroring step 1 of `performKanbanMove` (lines 338–343): find labels whose lowercased name is in `KanbanSettingsService.shared.managedLabelNames` and call `apiService.removeLabelsFromIssue`.
- Call it in both close paths **before/after** the state change:
  - `IssuesListViewModel.closeIssue(_:)` (line 165) — covers context-menu Close and batch close.
  - `IssueDetailViewModel.closeIssue()` (line 110) — covers the detail header and the "Save and Close Issue" flow (`CommentFormSheet` → `commentFormSuccessAndClose`).
- Ensure the upserted issue reflects the removed label (re-fetch or strip locally) so the card jumps to Done immediately. Leave non-managed `kanban-*` labels (other configs) untouched, consistent with `performKanbanMove`.

---

## #96 — Bottom progress bar for background work

**Introduce one serial queue** as the single point through which background mutating operations run, exposing observable progress.

- New `Services/BackgroundTaskQueue.swift`: `@MainActor final class BackgroundTaskQueue: ObservableObject`. Holds a list of pending operations each with a display `title`; publishes `total`, `currentIndex`, `currentTitle`, `isProcessing`. A single processing loop runs operations **one at a time** (fixing today's overlapping fire-and-forget `Task`s). Support two enqueue styles:
  - fire-and-forget `enqueue(title:_ operation:)` for Kanban/batch;
  - `enqueueAwaiting(title:_ operation:) async -> T` (continuation-backed) so the transfer sheet can await aggregate results while the footer still observes shared progress.
- Own a shared instance on `IssuesListViewModel` (already `@MainActor`, already the shared object injected into views).

**Route existing work through the queue:**
- `KanbanBoardView.handleDrop` (`Task { await viewModel.moveIssue... }`, lines ~202–208) → enqueue each `performKanbanMove` with title = issue title. `moveIssues`/`moveIssue` (IssuesListViewModel lines 266–292) enqueue their per-issue reconciliation instead of looping inline; optimistic cache updates stay immediate.
- Batch loops in `ContentView.swift` (delete 408–417, close 424–432, clone 440–448, assign 474–482) → enqueue per issue (title = issue title). Prefer moving these loops into view-model methods so they enqueue centrally.
- Cross-repo copy/move (`copyIssues`/`moveIssues`, lines 393–434) → each per-issue `copyIssue`/`moveIssue` becomes a queued operation titled with the issue title; the transfer sheet uses `enqueueAwaiting` to still show its own summary. This yields the issue's example: `Processing issue 3 of 7 (Copy to multiple repositories)…`.

**Footer UI:** attach `.safeAreaInset(edge: .bottom)` to the `NavigationSplitView` in `ContentView.swift` (modifier chain ~line 370). When `queue.isProcessing`, show a `Divider()` + row: a `ProgressView(value:)` plus `Text("Processing issue \(currentIndex) of \(total) (\(currentTitle))…")`. Hidden (zero height) when idle. This replaces/absorbs the ad-hoc `kanbanToastMessage` hidden-by-filter notice where it overlaps, or the two coexist (toast for "hidden by filter", footer for progress).

---

## Files to modify (summary)

- `Models/Repository.swift`, `Models/Issue.swift` (display helper), `Models/FilterOptions.swift`
- `Networking/GraphQLQueries.swift` (repo fragments + `toRepository()`)
- `Services/AppStateService.swift`, `Services/GitHubAPIService.swift`, **new** `Services/BackgroundTaskQueue.swift`
- `ViewModels/IssuesListViewModel.swift`, `ViewModels/IssueDetailViewModel.swift`
- `Views/Settings/SettingsView.swift`
- `Views/IssuesList/IssueContextMenu.swift`, `Views/IssuesList/TransferIssuesSheet.swift`
- `Views/IssueDetail/IssueDetailView.swift`, `Views/Kanban/KanbanBoardView.swift`
- `ContentView.swift`

## Verification

Build/run the macOS app (Xcode or `xcodebuild`) and exercise each issue against a real GitHub account that has at least one **archived** repo with open issues, plus a repo you only have READ access to:

- **#93:** With the new toggle **off**, confirm archived/read-only repos' issues are absent from list and Kanban. Turn it **on**: their issues appear with `" (read-only)"` after the repo name in both list and board; right-click items are disabled; detail Edit/Assign/Pin/Delete are disabled; the card can't be dragged.
- **#94:** Right-click an issue → Copy to Repository → select **multiple** repos → Copy; verify a copy lands in each destination and the summary reports all.
- **#95:** Give an open issue a `kanban-<Status>` label, then Close it via context menu and via "Save and Close Issue"; with State filter = All, confirm it now appears in the **Done** column (label removed on GitHub).
- **#96:** Drag several cards / run a batch close / copy to multiple repos; confirm the bottom bar shows `Processing issue X of N (title)…` advancing serially, and disappears when done.
