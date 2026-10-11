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
}
