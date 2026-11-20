//
//  IssueFetchAccumulatorTests.swift
//  GitIssuesTests
//
//  Issue #109: pages from concurrent open/closed searches are combined for progressive display.
//

import XCTest
@testable import GitIssues

@MainActor
final class IssueFetchAccumulatorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testCombinesPagesFromBothStreamsNewestFirst() {
        let acc = IssueFetchAccumulator()
        acc.add([Fixture.issue(id: "closed-old", state: .closed, updatedAt: t0)])
        acc.add([Fixture.issue(id: "open-new", state: .open, updatedAt: t0.addingTimeInterval(100))])
        acc.add([Fixture.issue(id: "closed-mid", state: .closed, updatedAt: t0.addingTimeInterval(50))])

        XCTAssertEqual(acc.snapshot.map(\.id), ["open-new", "closed-mid", "closed-old"])
        XCTAssertEqual(acc.count, 3)
    }

    func testDuplicateIDKeepsNewestCopy() {
        let acc = IssueFetchAccumulator()
        acc.add([Fixture.issue(id: "A", title: "newer", updatedAt: t0.addingTimeInterval(10))])
        acc.add([Fixture.issue(id: "A", title: "older", updatedAt: t0)])
        XCTAssertEqual(acc.snapshot.map(\.title), ["newer"])

        // An issue that moved between streams mid-fetch: the later (newer) copy replaces the earlier.
        let moved = IssueFetchAccumulator()
        moved.add([Fixture.issue(id: "B", state: .open, updatedAt: t0)])
        moved.add([Fixture.issue(id: "B", state: .closed, updatedAt: t0.addingTimeInterval(5))])
        XCTAssertEqual(moved.snapshot.first?.state, .closed)
        XCTAssertEqual(moved.count, 1)
    }

    func testEqualTimestampsOrderIsStable() {
        let acc = IssueFetchAccumulator()
        acc.add([Fixture.issue(id: "b", updatedAt: t0), Fixture.issue(id: "a", updatedAt: t0)])
        XCTAssertEqual(acc.snapshot.map(\.id), ["a", "b"])
    }

    func testEmptyAccumulator() {
        XCTAssertTrue(IssueFetchAccumulator().snapshot.isEmpty)
    }
}
