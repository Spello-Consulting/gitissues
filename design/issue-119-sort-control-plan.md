# Issue #119 — Enhance the Sort control

Status: **Draft for review — no code written yet.**
Branch: `feature/issue-119-sort-control`
Issue: [Spello-Consulting/gitissues#119](https://github.com/Spello-Consulting/gitissues/issues/119)

## 1. Background

The issue began as a bug report: *sorting closed issues by Issue # (High to Low) gave the wrong order*. The screenshot
was of the **Kanban board**, not the list. Investigation found:

- `SortOption.sort` is correct, and the list view sorts correctly.
- `Kanban.columns` (`Models/KanbanState.swift`) orders each column as *issues with a `gitissues:order` key, sorted by
  key*, then *issues without a key, in sort order*. The Sort control therefore only breaks ties between issues that
  share a key.
- Every issue that has ever been dragged on the board carries a key, so the Closed column was in "dragged" order. The
  keys in the repo were heavily duplicated (`V` ×6, `l` ×4, `t` ×3, `z` ×2), and the screenshot matched them exactly:
  key groups in key order, Issue # descending *within* each group.
- The duplicates come from `handleDrop` (`Views/Kanban/KanbanBoardView.swift`). It uses only the nearest neighbour's
  key, and an un-dragged issue has no key, so it counts as "no bound". `keyBetween(nil, nil)` is always `V` and
  `keyBetween("V", nil)` is always `l`, so repeated drops beside un-keyed cards give the same key again.

The issue has been rewritten as an enhancement: make the Sort control behave sensibly in each view mode. Dragged
ordering becomes an explicit, switchable part of the Sort control instead of an invisible override.

## 2. Requirements

### 2.1 Normal mode (issue list)

- Sort control offers the same 6 options as today.
- Issues sort by the selected option. Pinned issues still appear at the top.
- `gitissues:order` tags in issue bodies are ignored.

### 2.2 Kanban mode

- Sort control offers the same 6 options **plus a "Kanban Dragged" toggle**. The toggle is independent of the 6
  options: one of the 6 is always selected, and "Kanban Dragged" can be on or off.
- **On:** issues sort by their order key first, then by the selected option.
- **Off:** order keys are ignored. Issues sort by the selected option only.
- Pinned state is ignored on the board.

### 2.3 Decisions agreed in review

| # | Decision |
|---|---|
| 1 | With "Kanban Dragged" **off**, reordering within a column is disabled. Dropping on another column still moves the issue (state label change) but **does not write an order key**. |
| 2 | With "Kanban Dragged" **on**, issues without a key follow the keyed ones, in selected-sort order (current behaviour). |
| 3 | "Kanban Dragged" defaults to **on**, so existing manual orderings keep working. It is persisted with the other filter state; the field is optional so older saved state still loads. |
| 4 | The 6 normal options are **one setting shared by both modes**. "Kanban Dragged" is a separate toggle shown only in Kanban mode; its value is kept when switching back to the list. |

### 2.4 Additional scope: duplicate order keys

With "Kanban Dragged" on, a card dropped between two cards that share a key (or beside un-keyed cards) would still snap
back to sort order. The drop logic is fixed as part of this change so the key written always puts the card where it
was dropped (section 4.4).

## 3. Design overview

| Area | Change |
|---|---|
| `FilterOptions` | New `kanbanDragged: Bool = true`. Not used by `matches()`. |
| `AppStateService` | `FilterState.kanbanDragged: Bool?`, saved and loaded (missing → `true`). |
| `IssuesListViewModel` | `filteredIssues` becomes *filtered + sorted only* (no pin handling). New `listIssues` = pinned first, derived from `filteredIssues` and `pinnedIssueIDs`. |
| `ContentView` | The list uses `listIssues`; the board keeps using `filteredIssues`. Passes `kanbanViewEnabled` to `FilterBarView`. |
| `FilterBarView` | New `isKanbanMode` input. Menu shows checkmarks; "Kanban Dragged" toggle in Kanban mode only. Label shows both parts when the toggle is on. |
| `Kanban.columns` | New `useDragOrder: Bool`. Off → no keyed/unkeyed split; incoming (already sorted) order. On → current behaviour with an explicit tie-break (section 4.3). |
| `KanbanBoardView` | Reordering within a column disabled when off; drop computation fixed (4.4); `orderKey` optional when off. |
| `IssuesListViewModel` Kanban moves | `moveIssue(s)` accept an optional key; no key → label/state change only, existing body marker untouched. |

## 4. Details

### 4.1 Sort control

Kanban mode menu:

```
Kanban Dragged       ✓
─────────────
Updated (Newest)     ✓
Updated (Oldest)
─────────────
Created (Newest)
Created (Oldest)
─────────────
Issue # (High to Low)
Issue # (Low to High)
```

Menu label: `Kanban Dragged + Issue # (High to Low)` when on, `Issue # (High to Low)` when off. Normal mode shows the
first six rows only.

### 4.2 Pinned issues

`applyFiltersAndSort` stops moving pinned issues to the front. A second small pipeline,
`CombineLatest($filteredIssues, $pinnedIssueIDs)`, produces `listIssues` (pinned first, order otherwise preserved).
The issue-count header continues to use `filteredIssues.count`, which is unchanged.

### 4.3 Column ordering (`Kanban.columns`)

- `useDragOrder == false`: each issue is placed in its column (placement rules unchanged) and the column keeps the
  incoming order, which is already the selected sort.
- `useDragOrder == true`: keyed issues first, sorted by key; ties broken by **incoming index** (explicit, not relying on
  `sorted` stability); then unkeyed issues in incoming order.

### 4.4 Drop logic and duplicate keys

`handleDrop` works on the displayed column `L` (excluding the issues being moved) and the insert index `i`.
`A = L[i-1]`, `B = L[i]`. Only runs when "Kanban Dragged" is on.

| Situation | Action |
|---|---|
| `A.key < B.key` (or one side is the edge) | `K = keyBetween(A.key, B.key)`. No extra writes. |
| `A` keyed, `B` unkeyed or edge | `K = keyBetween(A.key, nil)`. No extra writes. |
| `A.key == B.key` (tie) | Re-key the tie members from `B` to the end of the group, together with `K`, using `keysBetween(A.key, nextDistinctKey, count: 1 + n)`; `K` takes the first key, the `n` members the rest, in their current order. Writes: `n`. |
| `A` unkeyed (drop lands in the unkeyed region) | Key the unkeyed run from its start to `A`, plus `K`, with ascending keys after the last keyed issue (`keysBetween(lastKeyed.key, nil, count:)`). Writes: the length of that run. |
| No neighbours (empty column) | `K = keyBetween(nil, nil)`. |

Re-keyed neighbours are written through the same path as a normal key write (`BackgroundTaskQueue`, with the
progress bar from issue #96). Typical boards have small columns, so the write count is small. The Closed column can be
large; a drop deep inside its unkeyed region writes one issue per card above the drop point.

When "Kanban Dragged" is **off**:

- A drop onto the same column is ignored.
- A drop onto another column performs the state change only. No order key is written and any existing marker is left
  untouched, so toggling back on restores the previous manual order.

## 5. Implementation steps

1. `SortOption`/`FilterOptions`/`AppStateService`: add `kanbanDragged`, persistence, tests for save/load
   (including old state without the field).
2. `Kanban.columns(useDragOrder:)` + tests.
3. Split pinned handling out of `applyFiltersAndSort`; add `listIssues`; update `ContentView`.
4. `FilterBarView`: mode-aware menu with checkmarks and toggle.
5. Drop logic: extract the neighbour/key computation into a pure helper (e.g. `KanbanDropPlanner`, next to
   `KanbanMovePlanner`) returning `(newKey, rekeyed: [(Issue, String)])`; wire `KanbanBoardView` and the
   view-model move methods; disable within-column reordering when off.
6. README and "What's New" entry for the next version.

## 6. Tests (pytest-equivalent in XCTest, in `GitIssuesTests/`)

- `KanbanColumnsTests`: drag order on/off; ties resolved by selected sort (all 6 options); unkeyed after keyed; the
  closed column matches the screenshot data from #119 (keys `V,V,V,V,V,l,l,l,t,t,t,x,z,z,zl`) — on gives key groups
  with Issue # descending inside, off gives pure Issue # descending.
- New `KanbanDropPlannerTests`: every row of the table in 4.4, plus "result key strictly between neighbours" and
  "displayed order after applying the plan equals the intended order".
- Filter-state persistence: round trip, and decoding saved state without `kanbanDragged`.
- List pipeline: pinned first in `listIssues`; `filteredIssues` has no pin reordering.

## 7. Risks and open points

- **Write count on first drops in legacy columns.** Re-keying writes to neighbours' GitHub issue bodies, with the
  usual rate limits and ~1.4 s per write measured in #109. Expected to be small; revisit if the Closed column proves
  slow in practice.
- **Existing duplicate keys are not rewritten in bulk.** They are healed locally, one tie group at a time, when a drop
  touches them. A bulk repair is out of scope.
- **Version bump** to be decided at release time.
