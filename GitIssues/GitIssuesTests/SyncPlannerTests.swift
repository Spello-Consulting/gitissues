//
//  SyncPlannerTests.swift
//  GitIssuesTests
//
//  Issue #109: full vs incremental sync decision.
//

import XCTest
@testable import GitIssues

@MainActor
final class SyncPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoCacheMeansFullSync() {
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: nil, lastSyncAt: nil, now: now), .full)
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: now, lastSyncAt: nil, now: now), .full)
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: nil, lastSyncAt: now, now: now), .full)
    }

    func testRecentFullSyncAllowsIncrementalReachingBackByOverlap() {
        let full = now.addingTimeInterval(-60)
        let last = now.addingTimeInterval(-30)

        let mode = SyncPlanner.mode(lastFullSyncAt: full, lastSyncAt: last, now: now)

        XCTAssertEqual(mode, .incremental(since: last.addingTimeInterval(-SyncPlanner.incrementalOverlap)))
    }

    func testFullSyncOlderThanReconcileIntervalForcesFull() {
        let full = now.addingTimeInterval(-SyncPlanner.fullReconcileInterval - 1)
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: full, lastSyncAt: now.addingTimeInterval(-5), now: now), .full)
    }

    func testJustInsideReconcileIntervalIsStillIncremental() {
        let full = now.addingTimeInterval(-SyncPlanner.fullReconcileInterval + 1)
        let mode = SyncPlanner.mode(lastFullSyncAt: full, lastSyncAt: full, now: now)
        if case .incremental = mode {} else { XCTFail("Expected incremental, got \(mode)") }
    }

    func testClockGoingBackwardsForcesFull() {
        let future = now.addingTimeInterval(120)
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: future, lastSyncAt: future, now: now), .full)
    }

    func testLastSyncBeforeFullSyncIsInconsistentSoFull() {
        let full = now.addingTimeInterval(-60)
        XCTAssertEqual(SyncPlanner.mode(lastFullSyncAt: full, lastSyncAt: full.addingTimeInterval(-10), now: now), .full)
    }
}
