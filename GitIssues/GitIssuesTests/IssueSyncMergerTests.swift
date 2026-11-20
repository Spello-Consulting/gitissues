//
//  IssueSyncMergerTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #100: a background sync response must not overwrite a just-saved local edit.
//

import XCTest
@testable import GitIssues

@MainActor
final class IssueSyncMergerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func pending(_ issue: Issue, at appliedAt: Date) -> [String: PendingIssueUpdate] {
        [issue.id: PendingIssueUpdate(issue: issue, appliedAt: appliedAt)]
    }

    func testNoPendingUpdatesReturnsIncomingUnchanged() {
        var pendingUpdates: [String: PendingIssueUpdate] = [:]
        let incoming = [Fixture.issue(id: "A", title: "Server")]

        let merged = IssueSyncMerger.merge(incoming: incoming, pending: &pendingUpdates, fetchStartedAt: t0, now: t0)

        XCTAssertEqual(merged, incoming)
    }

    /// The reported bug: the sync started, the user saved, then the (stale) response arrived.
    func testFetchStartedBeforeEditKeepsLocalEdit() {
        let edited = Fixture.issue(id: "A", title: "Edited", state: .closed, updatedAt: t0.addingTimeInterval(5))
        let stale = Fixture.issue(id: "A", title: "Old", state: .open, updatedAt: t0)
        var pendingUpdates = pending(edited, at: t0.addingTimeInterval(5))

        let merged = IssueSyncMerger.merge(
            incoming: [stale],
            pending: &pendingUpdates,
            fetchStartedAt: t0.addingTimeInterval(2),
            now: t0.addingTimeInterval(6)
        )

        XCTAssertEqual(merged.first?.title, "Edited")
        XCTAssertEqual(merged.first?.state, .closed)
        XCTAssertNotNil(pendingUpdates["A"], "Edit is still unconfirmed so it stays protected")
    }

    func testFetchAfterEditButServerBehindKeepsLocalEdit() {
        // GitHub can briefly serve the old copy even for a request issued after the save.
        let edited = Fixture.issue(id: "A", title: "Edited", updatedAt: t0.addingTimeInterval(5))
        let stale = Fixture.issue(id: "A", title: "Old", updatedAt: t0)
        var pendingUpdates = pending(edited, at: t0.addingTimeInterval(5))

        let merged = IssueSyncMerger.merge(
            incoming: [stale],
            pending: &pendingUpdates,
            fetchStartedAt: t0.addingTimeInterval(7),
            now: t0.addingTimeInterval(8)
        )

        XCTAssertEqual(merged.first?.title, "Edited")
    }

    func testServerCaughtUpTakesServerCopyAndClearsPending() {
        let edited = Fixture.issue(id: "A", title: "Edited", updatedAt: t0.addingTimeInterval(5))
        let confirmed = Fixture.issue(id: "A", title: "Edited by server", updatedAt: t0.addingTimeInterval(5))
        var pendingUpdates = pending(edited, at: t0.addingTimeInterval(5))

        let merged = IssueSyncMerger.merge(
            incoming: [confirmed],
            pending: &pendingUpdates,
            fetchStartedAt: t0.addingTimeInterval(7),
            now: t0.addingTimeInterval(8)
        )

        XCTAssertEqual(merged.first?.title, "Edited by server")
        XCTAssertNil(pendingUpdates["A"])
    }

    func testExpiredPendingUpdateIsDropped() {
        let edited = Fixture.issue(id: "A", title: "Edited", updatedAt: t0.addingTimeInterval(5))
        let older = Fixture.issue(id: "A", title: "Server", updatedAt: t0)
        var pendingUpdates = pending(edited, at: t0.addingTimeInterval(5))
        let later = t0.addingTimeInterval(5 + IssueSyncMerger.gracePeriod + 1)

        let merged = IssueSyncMerger.merge(
            incoming: [older],
            pending: &pendingUpdates,
            fetchStartedAt: later,
            now: later
        )

        XCTAssertEqual(merged.first?.title, "Server")
        XCTAssertTrue(pendingUpdates.isEmpty)
    }

    func testOnlyEditedIssuesAreProtected() {
        let edited = Fixture.issue(id: "A", title: "Edited", updatedAt: t0.addingTimeInterval(5))
        let incoming = [
            Fixture.issue(id: "A", title: "Old", updatedAt: t0),
            Fixture.issue(id: "B", title: "Other", updatedAt: t0)
        ]
        var pendingUpdates = pending(edited, at: t0.addingTimeInterval(5))

        let merged = IssueSyncMerger.merge(
            incoming: incoming,
            pending: &pendingUpdates,
            fetchStartedAt: t0.addingTimeInterval(1),
            now: t0.addingTimeInterval(6)
        )

        XCTAssertEqual(merged.map(\.title), ["Edited", "Other"])
    }

    // MARK: - reconcile (issue #109: progressive loading)

    private func reconcile(
        incoming: [Issue],
        deletions: inout Set<String>,
        insertions: inout [Issue],
        complete: Bool
    ) -> [Issue] {
        var updates: [String: PendingIssueUpdate] = [:]
        return IssueSyncMerger.reconcile(
            incoming: incoming,
            pendingUpdates: &updates,
            pendingDeletions: &deletions,
            pendingInsertions: &insertions,
            fetchStartedAt: t0,
            isComplete: complete,
            now: t0
        )
    }

    func testPartialResultKeepsPendingDeletionHidden() {
        // The deleted issue is absent from an early page only because it hasn't loaded yet; the
        // deletion must not be treated as acknowledged, or it would reappear on a later page.
        var deletions: Set<String> = ["gone"]
        var insertions: [Issue] = []

        let partial = reconcile(incoming: [Fixture.issue(id: "A")], deletions: &deletions, insertions: &insertions, complete: false)
        XCTAssertEqual(deletions, ["gone"])
        XCTAssertEqual(partial.map(\.id), ["A"])

        let later = reconcile(
            incoming: [Fixture.issue(id: "A"), Fixture.issue(id: "gone")],
            deletions: &deletions, insertions: &insertions, complete: false
        )
        XCTAssertEqual(later.map(\.id), ["A"], "Pending deletion stays hidden when its page arrives")
    }

    func testCompleteResultAcknowledgesAbsentDeletion() {
        var deletions: Set<String> = ["gone"]
        var insertions: [Issue] = []

        _ = reconcile(incoming: [Fixture.issue(id: "A")], deletions: &deletions, insertions: &insertions, complete: true)

        XCTAssertTrue(deletions.isEmpty, "Server confirmed the deletion")
    }

    func testPartialResultPrependsUnconfirmedInsertionAndKeepsIt() {
        let created = Fixture.issue(id: "new")
        var deletions: Set<String> = []
        var insertions = [created]

        let partial = reconcile(incoming: [Fixture.issue(id: "A")], deletions: &deletions, insertions: &insertions, complete: false)

        XCTAssertEqual(partial.map(\.id), ["new", "A"])
        XCTAssertEqual(insertions.map(\.id), ["new"], "Still unconfirmed")
    }

    func testCompleteResultAcknowledgesPresentInsertionWithoutDuplicating() {
        let created = Fixture.issue(id: "new")
        var deletions: Set<String> = []
        var insertions = [created]

        let result = reconcile(
            incoming: [Fixture.issue(id: "new"), Fixture.issue(id: "A")],
            deletions: &deletions, insertions: &insertions, complete: true
        )

        XCTAssertEqual(result.map(\.id), ["new", "A"])
        XCTAssertTrue(insertions.isEmpty)
    }

    // MARK: - applyIncremental (issue #109: incremental sync)

    private func applyIncremental(
        existing: [Issue],
        changed: [Issue],
        deletions: Set<String> = [],
        insertions: inout [Issue],
        updates: inout [String: PendingIssueUpdate]
    ) -> [Issue] {
        IssueSyncMerger.applyIncremental(
            existing: existing,
            changed: changed,
            pendingUpdates: &updates,
            pendingDeletions: deletions,
            pendingInsertions: &insertions,
            fetchStartedAt: t0,
            now: t0
        )
    }

    func testIncrementalReplacesChangedInPlaceAndLeavesTheRest() {
        var insertions: [Issue] = []
        var updates: [String: PendingIssueUpdate] = [:]
        let existing = [Fixture.issue(id: "A", title: "a"), Fixture.issue(id: "B", title: "b"), Fixture.issue(id: "C", title: "c")]

        let result = applyIncremental(
            existing: existing,
            changed: [Fixture.issue(id: "B", title: "b2")],
            insertions: &insertions, updates: &updates
        )

        XCTAssertEqual(result.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(result.map(\.title), ["a", "b2", "c"])
    }

    func testIncrementalNeverTreatsAbsenceAsDeletion() {
        var insertions: [Issue] = []
        var updates: [String: PendingIssueUpdate] = [:]
        let existing = [Fixture.issue(id: "A"), Fixture.issue(id: "B")]

        let result = applyIncremental(existing: existing, changed: [], insertions: &insertions, updates: &updates)

        XCTAssertEqual(result.map(\.id), ["A", "B"])
    }

    func testIncrementalInsertsNewIssuesAtFront() {
        var insertions: [Issue] = []
        var updates: [String: PendingIssueUpdate] = [:]

        let result = applyIncremental(
            existing: [Fixture.issue(id: "A")],
            changed: [Fixture.issue(id: "N1"), Fixture.issue(id: "N2")],
            insertions: &insertions, updates: &updates
        )

        XCTAssertEqual(result.map(\.id), ["N1", "N2", "A"])
    }

    func testIncrementalKeepsPendingLocalEditOverStaleServerCopy() {
        let edited = Fixture.issue(id: "A", title: "Edited", updatedAt: t0.addingTimeInterval(5))
        var updates = pending(edited, at: t0.addingTimeInterval(5))
        var insertions: [Issue] = []

        let result = IssueSyncMerger.applyIncremental(
            existing: [edited],
            changed: [Fixture.issue(id: "A", title: "Old", updatedAt: t0)],
            pendingUpdates: &updates,
            pendingDeletions: [],
            pendingInsertions: &insertions,
            fetchStartedAt: t0.addingTimeInterval(2),
            now: t0.addingTimeInterval(6)
        )

        XCTAssertEqual(result.first?.title, "Edited")
    }

    func testIncrementalDoesNotReviveAPendingDeletion() {
        var insertions: [Issue] = []
        var updates: [String: PendingIssueUpdate] = [:]

        let result = applyIncremental(
            existing: [Fixture.issue(id: "A")],
            changed: [Fixture.issue(id: "gone"), Fixture.issue(id: "A", title: "A2")],
            deletions: ["gone"],
            insertions: &insertions, updates: &updates
        )

        XCTAssertEqual(result.map(\.id), ["A"])
        XCTAssertEqual(result.first?.title, "A2")
    }

    func testIncrementalAcknowledgesInsertionOnceServerReturnsIt() {
        let created = Fixture.issue(id: "new")
        let unconfirmed = Fixture.issue(id: "still-unconfirmed")
        var insertions = [created, unconfirmed]
        // `upsertIssueInCache` registers a pending update alongside every insertion.
        var updates = pending(unconfirmed, at: t0)

        // The list already shows both optimistic insertions (they were prepended when created).
        _ = applyIncremental(
            existing: insertions,
            changed: [Fixture.issue(id: "new", title: "from server")],
            insertions: &insertions, updates: &updates
        )

        XCTAssertEqual(insertions.map(\.id), ["still-unconfirmed"])
    }

    // A locally-created issue that the server never returns (deleted on github.com before any
    // sync saw it) must not be re-injected forever.
    func testCompleteResultExpiresInsertionOnceGracePeriodHasLapsed() {
        let created = Fixture.issue(id: "new")
        var insertions = [created]
        var updates = pending(created, at: t0)
        var deletions: Set<String> = []

        let result = IssueSyncMerger.reconcile(
            incoming: [Fixture.issue(id: "A")],
            pendingUpdates: &updates,
            pendingDeletions: &deletions,
            pendingInsertions: &insertions,
            fetchStartedAt: t0.addingTimeInterval(120),
            isComplete: true,
            now: t0.addingTimeInterval(120)
        )

        XCTAssertEqual(result.map(\.id), ["A"])
        XCTAssertTrue(insertions.isEmpty)
    }

    func testCompleteResultKeepsInsertionWithinGracePeriod() {
        let created = Fixture.issue(id: "new")
        var insertions = [created]
        var updates = pending(created, at: t0)
        var deletions: Set<String> = []

        let result = IssueSyncMerger.reconcile(
            incoming: [Fixture.issue(id: "A")],
            pendingUpdates: &updates,
            pendingDeletions: &deletions,
            pendingInsertions: &insertions,
            fetchStartedAt: t0.addingTimeInterval(5),
            isComplete: true,
            now: t0.addingTimeInterval(5)
        )

        XCTAssertEqual(result.map(\.id), ["new", "A"], "Search index may not show it yet")
        XCTAssertEqual(insertions.map(\.id), ["new"])
    }
}
