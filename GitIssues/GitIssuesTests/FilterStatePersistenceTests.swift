//
//  FilterStatePersistenceTests.swift
//  GitIssuesTests
//
//  Issue #119: the Kanban "dragged order" toggle is saved with the filter state, and older saved
//  state (written before the field existed) must still load. These tests encode/decode the
//  `Codable` value directly so they never touch the real `UserDefaults`.
//

import XCTest
@testable import GitIssues

final class FilterStatePersistenceTests: XCTestCase {
    func testKanbanDraggedRoundTrips() throws {
        let state = AppState.FilterState(
            stateFilter: "Open",
            visibilityFilter: "All",
            involvementFilter: "All",
            selectedRepositories: [],
            selectedLabels: [],
            sortOption: "number-desc",
            kanbanDragged: false
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.FilterState.self, from: data)
        XCTAssertEqual(decoded.kanbanDragged, false)
        XCTAssertEqual(decoded.sortOption, "number-desc")
    }

    func testSavedStateWithoutKanbanDraggedStillDecodes() throws {
        let legacy = """
        {"stateFilter":"Open","visibilityFilter":"All","involvementFilter":"All",
         "selectedRepositories":[],"sortOption":"updated-desc"}
        """
        let decoded = try JSONDecoder().decode(AppState.FilterState.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.kanbanDragged, "Missing field decodes to nil; the loader treats nil as on")
    }

    func testFilterOptionsDefaultsKanbanDraggedOn() {
        XCTAssertTrue(FilterOptions().kanbanDragged)
    }
}

// MARK: - Pinned issues (list only)

@MainActor
final class PinnedFirstTests: XCTestCase {
    func testPinnedIssuesMoveToTheFrontKeepingRelativeOrder() {
        let issues = [("a", 5), ("b", 4), ("c", 3), ("d", 2)].map { Fixture.issue(id: $0.0, number: $0.1) }
        let result = IssuesListViewModel.pinnedFirst(issues, pinnedIDs: ["c", "b"])
        XCTAssertEqual(result.map(\.id), ["b", "c", "a", "d"])
    }

    func testNoPinsLeavesOrderUnchanged() {
        let issues = [("a", 5), ("b", 4)].map { Fixture.issue(id: $0.0, number: $0.1) }
        XCTAssertEqual(IssuesListViewModel.pinnedFirst(issues, pinnedIDs: []).map(\.id), ["a", "b"])
    }
}
