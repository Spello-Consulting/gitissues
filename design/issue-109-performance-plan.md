# Issue #109 — Performance Plan

Status: **Phases 0–2 complete, measured and committed (a Kanban move is now 1.4–2.1 s, was 3.3–4.3 s). Phase 4
implemented, awaiting measurement. Phase 3 (disk cache) not started.**
Branch: `feature/issue-109-performance`

## 1. Problem

| Symptom | Observed |
|---|---|
| Initial issue list takes ~15 s to populate | Same in Debug and Release → network-bound |
| Dragging a card to another Kanban lane takes several seconds | Background reconcile (the card itself moves instantly) |

## 2. Phase 0 results (Release build, 2026-11-18)

Timing instrumentation (`[PERF]` log lines, `PerfTimer`) was added and run against the real account.

### 2.1 Initial load — 17.9 s total

| Measure | Value |
|---|---|
| Issues returned | **468 — 7 open, 461 closed**, across 33 repos |
| Requests | 1 viewer login (418 ms) + **12 sequential search pages** |
| Time per page | 1.1–1.9 s (avg ≈ 1.45 s), ≈ 17.4 s for all pages |
| Response size | 19–82 KB per page (320 KB of body text in total) |
| JSON decode | 1–3 ms per page |
| Merge + filter + sort of 468 issues | 1.0 ms |

What this tells us:

1. **It is pure request latency**, ~1.5 s per search request, strictly serial. Payload size and CPU are irrelevant
   (a 60 KB response decodes in 2 ms). Slimming issue bodies out of the query (old "Phase 5") would not help and is
   **dropped**.
2. **98 % of the wait is closed issues.** The default view is *Open*, which has 7 issues, but the user waits for all 468.
3. **About a fifth of the fetched nodes are pull requests that are thrown away.** The search is `involves:@me`, which
   matches issues *and* PRs; the first five pages returned only 19–37 issues out of 50 nodes. Adding `is:issue`
   makes GitHub filter them out server-side → fewer pages for free. (It also keeps us further from GitHub's
   1,000-result search cap, which otherwise silently truncates results — PRs count towards it.)
4. The **background sync repeats all 12 pages every interval** (seen in the log: a second full fetch started a minute
   after the first). That is ~17 s of requests per sync and needlessly burns API rate limit.

### 2.2 Kanban drag — 3.3 s

| Step | Time |
|---|---|
| `read1` (IssueDetail incl. 100 comments) | 425 ms |
| `ensureLabel` (list repo labels) | 418 ms |
| `addLabels` (mutation) | **1,049 ms** |
| `updateIssue` (mutation) | **969 ms** |
| `read2` (IssueDetail again) | 444 ms |
| upsert into cache | 0.8 ms |

This issue had no existing Kanban label, so there was no `removeLabels` call. A lane-to-lane move that *does* carry a
Kanban label adds another ~1 s mutation, i.e. **~4.3 s**.

What this tells us:

1. Reads cost ~0.42 s (the round-trip floor); **each mutation costs ~1.0 s**. Mutations are what hurt, so the best
   fix is to do the whole write in **one** mutation, not just to batch requests.
2. `ensureLabel` and `read2` are pure waste (cacheable / already in the `updateIssue` response).
3. Queue wait was 38 ms — the serial queue is not the bottleneck.

### 2.3 CPU — not a problem at this size

Every CPU measure was negligible at 468 issues (decode ≤ 3 ms, filter/sort/merge ≈ 1 ms, cache upsert < 1 ms; no
Kanban column calculation exceeded the 10 ms logging threshold). The CPU concerns I raised before measuring
(main-actor decoding, whole-body hashing, per-render grouping) are **demoted to "only if the app feels laggy"**. The
one cheap item worth keeping is the per-access regex compile in `kanbanOrderKey` (see Phase 4).

### 2.4 Phase 1 results (Release build, same account)

| Measure | Before | After |
|---|---|---|
| Open issues visible | 17.9 s | **1.4 s** |
| Everything loaded (468 issues) | 17.9 s | 11.2 s (in the background; list is usable from 1.4 s) |
| Requests | 13 serial | 1 open + 5 closed, running concurrently |

* Open stream: 1 request, 1.3 s. Closed stream: 5 pages of 100, 11.0 s.
* **Per-request time grows with the number of issues returned** (≈ 0.5 s fixed + ≈ 20 ms per issue): 100-issue pages took
  2.4–2.8 s versus ~1.4 s for 50. So bigger pages only save the fixed cost, not the per-issue cost, and the closed
  stream is now bound by its serial paging.
* The 11 s of background loading is what Phase 3 removes from the user's path: with a disk cache the closed issues
  are already on screen at launch, and incremental sync means a full re-download is rare.
* *Optional, not planned:* splitting the closed stream into 3–4 date windows (`updated:` ranges) fetched concurrently
  would cut the full load to ~4 s, at the cost of more concurrent requests against GitHub's rate limits. Revisit
  only if Phase 3 doesn't make this moot.
* **New finding — board CPU is no longer negligible.** With the Done column now holding ~460 cards, computing the
  column (`kanban column 'Done'`) costs **20–35 ms per render**, and it renders at least twice per page published.
  This is the per-access regex in `kanbanOrderKey` (§2.3), so the Phase 4 order-key fix is now justified by data
  and will be done right after Phase 2.

Kanban move re-measured (moving to Done, issue carried a Kanban label): **3.7 s** = `read1` 0.56 + `removeLabels` 1.22 +
`updateIssue` 1.47 + `read2` 0.44. Mutations cost 1.0–1.5 s each, reads ~0.45 s, confirming Phase 2.

## 3. Revised plan

Ordered by value. Each phase ships and is tested independently; commits per phase on the one feature branch.

### Phase 1 — Faster initial load (target: open issues visible in ~2 s)

1. **`is:issue`** added to the search query (drops PR nodes server-side).
2. **100 per page** (GitHub's maximum) instead of 50.
3. **Viewer login in parallel** with the first issues request (`async let`); saves ~0.4 s.
4. **Open and closed as two concurrent streams** (`is:open` and `is:closed`). Pagination within a stream is
   inherently serial, but two independent searches can run side by side. The 7 open issues arrive after one request
   (~1.5 s); closed ones fill in behind them. Two concurrent requests is well within GitHub's secondary rate-limit
   guidance; we won't go beyond that.
5. **Progressive publishing**: each page is merged into `allIssues` as it arrives, so the Done column/closed filter
   fill in visibly instead of appearing all at once. The existing fetch-sequence and `IssueSyncMerger` protections stay,
   so late responses can't overwrite newer local edits. (Once Phase 3's cache exists, a refresh only swaps in the
   result at the end so cached rows never vanish mid-refresh.)
6. Spinner (`isLoading`) ends as soon as the first open page lands.

Expected result on this account: open issues in ~2 s; the full 461 closed issues in roughly 5 pages ≈ 7–9 s in the
background instead of 17 s of blocking.

### Phase 2 — Kanban move: ~3.3–4.3 s → ~2 s

Replace the 6–7 call chain with:

1. **One lightweight read** (labels, body, state — no comments, no activity). ~0.4 s. Kept so we still act on the
   current labels and body rather than a possibly stale cache.
2. **Label lookup from a per-repo cache** (`[repoID: [lowercased name: Label]]`) populated on first use and updated on
   `createLabel`; a miss falls back to one `repository.label(name:)` query and then `createLabel`. Cache is dropped on
   error. Saves ~0.4 s.
3. **One `updateIssue` mutation** carrying `labelIds` + `body` + `state`. Given the ~1 s per-mutation cost this is the
   largest saving (replaces `removeLabels` + `addLabels` + `updateIssue`, 2–3 s → ~1 s).
   - **Design change from the earlier draft:** I previously proposed aliased add/remove mutations to keep
     label changes "targeted". Measurement shows each mutation costs ~1 s *server-side*, so batching them probably
     saves little. `updateIssue(labelIds:)` *replaces* the whole label set, so the new set is built from the
     just-read labels: current labels, minus managed Kanban labels, plus the target label. The only clobber window is
     the ~0.4 s between the read and the write — shorter than today's ~3 s multi-step window, and the body is
     already written read-then-write.
4. **Use the mutation response** to update the cache and drop the second `fetchIssueDetail`.

`closeIssue` + `clearManagedKanbanLabels` (two sequential mutations today) get the same single-mutation treatment
(`GitHubAPIService.closeIssue`, used by both the list and detail view models).

Implementation notes / safeguards:

* Label-set calculation is a pure function (`KanbanMovePlanner.labelUpdate`) returning `nil` when the set is
  unchanged (reordering within a column), in which case `labelIds` is omitted and labels aren't touched at all.
* **Close path:** it works from the *cached* issue, whose labels come from the list query's `labels(first: 10)`. An
  issue showing 10 labels may have more that were cut off, so replacing the set would drop them. Such issues fall
  back to the old targeted remove-then-update route.
* **Stale label cache:** if the write fails and the repo's labels were cached, the cache is dropped and the move
  is retried once with a fresh lookup; otherwise the failure surfaces as before (and the card reverts).
* The move's open/closed decision now uses the freshly-read state rather than the cached one.
The optimistic UI and revert-on-failure behaviour are unchanged. Multi-card drags speed up by the same factor.

### Phase 3 — Persistent cache + incremental sync

1. **`IssueCacheStore`**: `[Issue]` + `viewerLogin` + `savedAt` + `schemaVersion` as JSON in the app sandbox
   (`Application Support/<bundle>/cache-<userLogin>.json`), written off the main thread, atomically, debounced.
2. **Launch sequence:** load cache → publish immediately (usable instantly) → background full fetch (Phase 1) → swap
   in the result via the existing merger. A refresh indicator shows while it runs.
3. **Incremental background sync:** timer ticks query `… updated:>=<lastSync − safety margin>` and merge the few changed
   issues (1 request instead of 12). Incremental sync can't see deletions, transfers or un-involvement, so a **full
   reconcile** still runs at launch, on the manual Refresh button, and every N-th tick.
4. **Invalidation:** cache cleared on sign-out/account change and on `schemaVersion` change; a corrupt or
   undecodable file is ignored and deleted.
5. **Settings:** a "Clear local cache" button.

### Phase 4 — Board CPU clean-up (justified by §2.4) — implemented, awaiting measurement

1. The order-marker regex is compiled once (`static let`) and skipped entirely for bodies that don't contain the
   marker literal. `Issue.kanbanOrderKey` is now a stored property computed when the issue is created (excluded from
   `Codable`; `Issue` has explicit `init`/`init(from:)`/`encode(to:)` to support it), instead of a regex compile and
   full-body scan on every access from the board's filter, sort and neighbour-lookup closures.
2. The board groups issues into columns in **one pass** per render (`Kanban.columns(for:in:…)`), instead of one pass
   over the whole list per column, with each state's label name lowercased once. Placement is covered by a parity
   test against the per-issue `Kanban.state(for:…)` rules.

Success measure: `kanban board grouping` (replaces the per-column `kanban column 'Done'` lines, which were 20–35 ms
each on 462 issues) should drop below the 10 ms logging threshold and so disappear from the info log.

Deferred, because the data shows no need: batched `upsertIssuesInCache` (a single upsert measured 0.3–2.9 ms),
hash-by-id `Issue`, off-main decoding (≤ 3 ms), search debounce. Revisit if the app feels laggy with a much larger
account.

### Dropped

* **Body slimming / data-model change** (old Phase 5): response size and decode time are not the bottleneck.

## 4. Testing

* Unit tests (in `GitIssuesTests/`):
  * Search-query builder: `is:issue`, state split, archived flag, `updated:>=` for incremental.
  * Open/closed stream merge: dedupe, ordering, late-response protection via `IssueSyncMerger`.
  * `IssueCacheStore`: round trip, schema mismatch, corrupt file, account switch, clear.
  * Incremental merge: changed issue replaces, new issue inserts, pending local edits still win.
  * Move label-set calculation (managed labels removed, others kept, target added, clutter-free/closed states).
  * Per-repo label cache: hit, miss, create, invalidate.
  * Cached `kanbanOrderKey` equals the regex result; marker `inject`/`strip` round trip unchanged.
* Manual (Release build), compared against the §2 baseline: cold launch (no cache), warm launch (cache), single drag
  with and without an existing Kanban label, 5-card multi-drag, 20 drags in a row, sign-out/sign-in, offline launch.
* The `[PERF]` lines stay in the app at info level, so before/after numbers come straight from the log.

## 5. Decision needed

The data shows **461 of 468 issues are closed**, and a closed issue only matters for the Kanban *Done* column and the
Closed/All filters. Even after Phase 1, loading all of them costs ~5 requests every cold start (and Phase 3's cache
removes most of that). Options:

* **A (recommended starting point): fetch all closed issues** as in Phase 1 — no behaviour change; they fill in
  behind the open ones.
* **B: fetch only recently closed issues** (e.g. closed in the last 90 days) at launch, with an explicit "Load older
  closed issues" action. Much faster and the Done column stays manageable, but older closed issues disappear from the
  list/board until loaded — a visible behaviour change.

I'd start with A, measure after Phases 1 and 3, and only do B if you still find the Done column noisy or the cold start
slow.

### Earlier decisions (all agreed)

1. Store issue data (including private-repo titles/bodies) in a JSON cache inside the app sandbox, with a
   "Clear local cache" button — **Yes**.
2. Closed issues may fill in a moment after open ones — **Yes**.
3. Body slimming — **left out** (now dropped on the data).
4. Version **1.2.0**, and update README/docs for the cache and new Settings control — **Yes**.

## 6. Risks

* **Stale cache at launch** (issue closed elsewhere) — mitigated by the immediate background full refresh.
* **Private issue content on disk** — in the sandbox container alongside the existing logs; the token stays in the
  Keychain, not in the cache.
* **GitHub secondary rate limits** — capped at two concurrent search streams.
* **`updateIssue(labelIds:)` replaces the label set** — computed from a fresh read; unit-tested; verified by manual
  drags (including issues with unrelated labels).
* **Search cap:** GitHub search returns at most 1,000 results; `is:issue` helps, but an account with more than
  1,000 issues would still be truncated. Not a regression, out of scope here.

## 7. Order of work

Phase 0 ✅ → Phase 1 → Phase 2 → Phase 3 → Phase 4 → re-measure against §2. One PR; I'll notify you when it's ready and
won't merge it.
