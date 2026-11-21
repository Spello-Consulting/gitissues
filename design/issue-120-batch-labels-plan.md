# Issue #120 — Apply labels when multiple issues are selected

Status: **Approved; implemented.**
Branch: `feature/issue-120-batch-labels`
Issue: [Spello-Consulting/gitissues#120](https://github.com/Spello-Consulting/gitissues/issues/120)

## 1. Background

The right-click menu offers **Labels…** for a single issue (`IssueLabelsSheet`, issue #97) but not when several issues
are selected (`issueContextMenu`, batch branch, `Views/IssuesList/IssueContextMenu.swift`). The issue raises two
questions:

1. Issues may already carry different labels. Does the operation *replace* their labels or *add* to them?
2. Selected issues may span repositories, and each repository has its own label list. How is that handled?

Relevant existing code:

| Piece | Where | Notes |
|---|---|---|
| Single-issue dialog | `Views/IssuesList/IssueLabelsSheet.swift` | Checklist of the repo's labels, search, `+` to create, Save applies the diff. |
| Diff logic | `LabelSelection` in `Models/Label.swift` | Kanban labels are hidden and always preserved. |
| Apply + cache update | `IssuesListViewModel.applyLabels(_:to:)` | Full-set semantics: makes the issue's labels *exactly* the selection. |
| Batch ops | `IssuesListViewModel.enqueueBatch*` | One queued op per issue → bottom progress bar. |
| Cross-repo label resolution | `GitHubAPIService.resolveLabels` (copy/move) | Matches labels **by name, case-insensitively**, creating missing ones with the source colour. |
| Menu wiring | `IssueActions` + `ContentView.issueActions` | Used by both the list and the Kanban board. |

## 2. Proposed behaviour

### 2.1 Replace vs add → tri-state checkboxes, only touched labels change

The dialog shows the **union** of labels and each label has a three-state checkbox reflecting the current selection:

| Display | Meaning |
|---|---|
| ☑ checked | every selected issue has the label |
| ➖ mixed | some selected issues have it |
| ☐ empty | none have it |

The user can click a label to *change* its state:

- empty → checked (**add** to all)
- checked → empty (**remove** from all)
- mixed → checked (add to all) → empty (remove from all) → mixed again (**untouched**)

Save applies only the labels the user actually changed. Labels left alone are never touched on any issue.

This answers the "replace or add?" question without a mode switch: it never replaces anything wholesale, issues that
differ stay different unless the user explicitly makes them the same, and removal is possible. It is the same
interaction as Gmail's label menu and GitHub's web UI for bulk label edits. For a single issue it degenerates to
today's plain checkbox, so one dialog can serve both cases.

*Alternatives considered:*

- **Always add** (never remove). Simplest, but you can't undo a mistaken bulk label without editing issues one at a
  time.
- **Add / Remove mode picker** (segmented control). Equivalent power, but two modes to explain and no view of the
  current state.
- **Replace**. Rejected: destroys per-issue labels the user can't see in the dialog.

### 2.2 Multiple repositories → match by name, create what's missing

Label IDs are per repository, so labels are identified across repositories by **lower-cased name** — the same rule
copy/move already uses.

- The dialog lists the union of label names across all repos in the selection (Kanban labels excluded, as today). The
  first repo's colour is shown.
- A label that exists in only some of the selected issues' repos shows a caption, e.g. *"in 2 of 3 repositories"*.
- **Adding** a label to issues in a repo that lacks it **creates it there** (with the shown colour) as part of Save —
  consistent with copy/move. The footer states this before saving: *"'triage' will be created in owner/repo-b."*
- **Removing** a label skips issues that don't have it (and repos that don't have it at all).
- The `+` button creates a new label in **every** repo in the selection that doesn't already have that name, and
  ticks it. Partial failures are reported by repo name in the dialog's error line.
- If everything is in one repo, nothing about this is visible: no captions, no creation notice.

*Alternative considered:* only offer labels common to all repos. Safe but very limiting — a typical selection of
issues from two repos would offer almost nothing — and users can already see that copy/move creates labels.

### 2.3 Menu and permissions

- The batch menu gains **Labels for N Issues…** (SF Symbol `tag`), placed after *Assign*.
- Disabled when any selected issue is in a read-only repo, like the other batch actions.
- Works from the Kanban board too, since it shares `issueContextMenu`.

## 3. Design

### 3.1 Pure planning logic (`Models/BatchLabelSelection.swift`)

All decisions live in pure functions so they can be unit-tested without the network. Labels are identified by
lower-cased name (`key`).

```swift
enum LabelCheckState { case none, mixed, all }
enum LabelIntent { case add, remove }          // absent = untouched

enum BatchLabelSelection {
    static func unionLabels(_ perRepo: [(repositoryID: String, labels: [Label])]) -> [UnionLabel]
    static func state(ofLabelKey: String, in issues: [Issue]) -> LabelCheckState
    static func nextIntent(current: LabelIntent?, initial: LabelCheckState) -> LabelIntent?
    static func displayState(initial: LabelCheckState, intent: LabelIntent?) -> LabelCheckState
    static func plan(issues: [Issue], intents: [String: LabelIntent]) -> [IssueLabelChange]
    static func missingLabels(plan:, repoLabels:, union:) -> [RepoLabelCreation]
    static func resolve(_ change: IssueLabelChange, repoLabels:) -> (add: [Label], removeIDs: [String])
    static func resultingLabels(current:, add:, removeIDs:) -> [Label]
}
```

Kanban labels are filtered with `Kanban.visibleLabels` / `isKanbanLabel`, as the old `LabelSelection` did.

### 3.2 View model

`IssuesListViewModel`:

- `fetchEditableLabels(for:)` already exists; the sheet calls it once per distinct repo. If any repo fails to load, the
  dialog refuses to continue (a partial list could cause duplicate-label creation).
- `applyLabels(_:to:)` and `LabelSelection` are replaced by `applyLabelChange(_:repoLabels:refreshDetail:)`, which the
  single-issue path calls too (a single issue is a plan of one change), so there is one code path. Their tests are
  superseded by `BatchLabelSelectionTests`.
- New `createLabels(_:)` creates missing labels and reports failures per repo.
- New `enqueueBatchLabels(_:repoLabels:)` enqueues one op per issue on `taskQueue`, so progress shows
  in the bottom bar like the other batch actions, and errors surface via `errorMessage`.
- For batch, skip the post-write `fetchIssueDetail` refresh that single-issue does (it doubles the API calls per
  issue). The cache is updated with the labels just applied; the next refresh picks up the server `updatedAt`.
- Label creation for missing repos happens in the sheet on Save **before** enqueuing (with a spinner), using the
  existing `createLabel(in:name:color:)`, so the queued ops only ever add/remove by real IDs.

### 3.3 UI

- Generalise `IssueLabelsSheet` to take `issues: [Issue]` (single issue = array of one). Header shows
  *"Labels — N issues in M repositories"* or the existing `#n title` for one.
- `LabelRow` gains an optional tri-state mode (`checkState`); single-issue usage is unchanged.
- `ContentView`: replace `issueForLabels: Issue?` with a `LabelsRequest` (like `TransferRequest`) holding
  `[Issue]`; `IssueActions` gains `batchEditLabels: (Set<Issue>) -> Void`.
- The selection is left as is after saving (the other batch operations do the same).
- The multi-selection panel also gets a **Labels for N Issues…** button, next to Assign.

### 3.4 Edge cases

| Case | Handling |
|---|---|
| Issue's label list truncated by the list query | Add/remove of labels are idempotent on GitHub; worst case a "remove" of a label that isn't there is a no-op. |
| Label exists in a repo with different case (`Bug` vs `bug`) | Matched case-insensitively; the repo's own spelling/ID is used. |
| Same name, different colours across repos | First repo's colour shown; each repo keeps its own colour. New labels created use the shown colour. |
| Label creation fails in one repo | Issues in that repo are skipped, the rest proceed, and the error names the repo. |
| Issue deleted/transferred meanwhile | Per-issue op fails, reported in the error message; others continue. |
| Nothing changed | Save is disabled. |
| GitHub rate limits | One add and/or one remove mutation per issue; same order of cost as batch assign. |

## 4. Tests (`GitIssuesTests`)

New `BatchLabelSelectionTests` (replaces the old `LabelSelectionTests`, using `Fixture.label`/issue helpers):

- `unionLabels`: de-dup by case-insensitive name, Kanban labels excluded, repo availability recorded.
- `state(ofLabelKey:)`: none / mixed / all, case-insensitive, Kanban labels ignored.
- `nextIntent`: cycles for none, all and mixed starts.
- `plan`: add skips issues that already have it; remove skips issues that lack it; untouched labels produce no
  changes; Kanban labels never appear; issues needing no change are omitted.
- `missingLabels`: only repos lacking the label, only for `add` intents, once per (repo, name).
- `resolve` / `resultingLabels`: per-repo IDs for adds, issue IDs for removals, Kanban labels preserved.

## 5. Docs

- README: note that **Labels…** works on multi-selections, with the tri-state and multi-repo behaviour in one
  paragraph.
- Release note: add to the next "What's New" (version to be decided at release time).

## 6. Implementation order

1. Pure planner + tests.
2. View model (`applyLabelChange`, `createLabels`, `enqueueBatchLabels`).
3. Generalise `IssueLabelsSheet` / `LabelRow`; wire `ContentView` and the context menu.
4. Manual check with a mixed selection across two repos (list and Kanban); README.
5. PR against `main`.

## 7. Decisions (all approved as recommended)

1. **Tri-state checkboxes (chosen)** vs. an Add/Remove mode picker vs. add-only. (§2.1)
2. **Create missing labels in other repos (chosen)** vs. skipping repos that lack the label. (§2.2)
3. **Generalise the existing sheet (chosen)** vs. a separate batch sheet. A single sheet avoids duplicated
   code; the cost is a small risk to the single-issue dialog, covered by the existing tests.
