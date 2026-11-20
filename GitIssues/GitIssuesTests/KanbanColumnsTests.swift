//
//  KanbanColumnsTests.swift
//  GitIssuesTests
//
//  Issue #109: the board groups issues into columns in one pass. Placement must match the
//  per-issue `Kanban.state(for:...)` rules, and ordering must match the old per-column logic.
//

import XCTest
@testable import GitIssues

@MainActor
final class KanbanColumnsTests: XCTestCase {
    private let backlog = KanbanState(name: "Backlog", isClosed: false)
    private let inProgress = KanbanState(name: "In Progress", isClosed: false)
    private let done = KanbanState(name: "Done", isClosed: true)
    private var states: [KanbanState] { [backlog, inProgress, done] }

    private func marker(_ key: String) -> String { "<!-- gitissues:order=\(key) -->" }

    private func columns(_ issues: [Issue]) -> [UUID: [Issue]] {
        Kanban.columns(for: issues, in: states, closedState: done, defaultState: backlog)
    }

    func testEveryStateHasAnEntryEvenWhenEmpty() {
        let result = columns([])
        XCTAssertEqual(Set(result.keys), Set(states.map(\.id)))
        XCTAssertTrue(result.values.allSatisfy(\.isEmpty))
    }

    func testPlacementMatchesPerIssueRules() {
        let issues = [
            Fixture.issue(id: "1", state: .open),
            Fixture.issue(id: "2", state: .open, labels: ["kanban-In Progress"]),
            Fixture.issue(id: "3", state: .open, labels: ["Kanban-in progress", "bug"]),
            Fixture.issue(id: "4", state: .open, labels: ["kanban-Backlog", "kanban-In Progress"]),
            Fixture.issue(id: "5", state: .closed, labels: ["kanban-In Progress"]),
            Fixture.issue(id: "6", state: .closed),
            Fixture.issue(id: "7", state: .open, labels: ["kanban-Someone Elses"])
        ]
        let grouped = columns(issues)

        for issue in issues {
            let expected = Kanban.state(for: issue, in: states, closedState: done, defaultState: backlog)
            let actual = states.first { state in grouped[state.id]?.contains(where: { $0.id == issue.id }) == true }
            XCTAssertEqual(actual, expected, "Issue \(issue.id)")
        }
        XCTAssertEqual(grouped.values.reduce(0) { $0 + $1.count }, issues.count, "No issue lost or duplicated")
    }

    func testKeyedIssuesComeFirstSortedByKeyThenUnkeyedInIncomingOrder() {
        let issues = [
            Fixture.issue(id: "u1"),
            Fixture.issue(id: "kB", body: marker("b")),
            Fixture.issue(id: "u2"),
            Fixture.issue(id: "kA", body: marker("a")),
            Fixture.issue(id: "kC", body: marker("c"))
        ]
        XCTAssertEqual(columns(issues)[backlog.id]?.map(\.id), ["kA", "kB", "kC", "u1", "u2"])
    }

    func testOrderingIsPerColumn() {
        let issues = [
            Fixture.issue(id: "p2", body: marker("2"), labels: ["kanban-In Progress"]),
            Fixture.issue(id: "b1", body: marker("1")),
            Fixture.issue(id: "p1", body: marker("1"), labels: ["kanban-In Progress"])
        ]
        let grouped = columns(issues)
        XCTAssertEqual(grouped[backlog.id]?.map(\.id), ["b1"])
        XCTAssertEqual(grouped[inProgress.id]?.map(\.id), ["p1", "p2"])
    }

    // MARK: - Issue #119: Sort control + "Kanban Dragged"

    /// The Closed column from the #119 screenshot: number → order key.
    private let closedKeys: [(number: Int, key: String)] = [
        (92, "V"), (93, "V"), (99, "V"), (106, "V"), (109, "V"),
        (94, "l"), (101, "l"), (105, "l"),
        (96, "t"), (102, "t"), (103, "t"),
        (104, "x"), (95, "z"), (97, "z"), (100, "zl")
    ]

    private func closedIssues() -> [Issue] {
        closedKeys.map {
            Fixture.issue(id: "I\($0.number)", number: $0.number, body: marker($0.key), state: .closed)
        }
    }

    private func closedColumn(sort: SortOption, useDragOrder: Bool) -> [Int] {
        let sorted = sort.sort(closedIssues())
        let grouped = Kanban.columns(
            for: sorted, in: states, closedState: done, defaultState: backlog, useDragOrder: useDragOrder
        )
        return (grouped[done.id] ?? []).map(\.number)
    }

    func testDragOrderOffIgnoresKeysAndUsesSelectedSortOnly() {
        XCTAssertEqual(
            closedColumn(sort: .numberDesc, useDragOrder: false),
            [109, 106, 105, 104, 103, 102, 101, 100, 99, 97, 96, 95, 94, 93, 92]
        )
        XCTAssertEqual(
            closedColumn(sort: .numberAsc, useDragOrder: false),
            [92, 93, 94, 95, 96, 97, 99, 100, 101, 102, 103, 104, 105, 106, 109]
        )
    }

    func testDragOrderOnGroupsByKeyThenSelectedSortWithinEachGroup() {
        // Key groups V, l, t, x, z, zl; Issue # descending inside each group (the #119 screenshot).
        XCTAssertEqual(
            closedColumn(sort: .numberDesc, useDragOrder: true),
            [109, 106, 99, 93, 92, 105, 101, 94, 103, 102, 96, 104, 97, 95, 100]
        )
        XCTAssertEqual(
            closedColumn(sort: .numberAsc, useDragOrder: true),
            [92, 93, 99, 106, 109, 94, 101, 105, 96, 102, 103, 104, 95, 97, 100]
        )
    }

    func testDragOrderOnKeepsUnkeyedAfterKeyedInSelectedSortOrder() {
        let issues = SortOption.numberDesc.sort([
            Fixture.issue(id: "a", number: 5),
            Fixture.issue(id: "b", number: 9),
            Fixture.issue(id: "c", number: 1, body: marker("m")),
            Fixture.issue(id: "d", number: 3, body: marker("a"))
        ])
        let on = Kanban.columns(for: issues, in: states, closedState: done, defaultState: backlog, useDragOrder: true)
        let off = Kanban.columns(for: issues, in: states, closedState: done, defaultState: backlog, useDragOrder: false)
        XCTAssertEqual(on[backlog.id]?.map(\.id), ["d", "c", "b", "a"])
        XCTAssertEqual(off[backlog.id]?.map(\.id), ["b", "a", "d", "c"])
    }

    func testPlacementIsTheSameRegardlessOfDragOrder() {
        let issues = [
            Fixture.issue(id: "1", body: marker("a")),
            Fixture.issue(id: "2", body: marker("b"), labels: ["kanban-In Progress"]),
            Fixture.issue(id: "3", state: .closed)
        ]
        let on = Kanban.columns(for: issues, in: states, closedState: done, defaultState: backlog, useDragOrder: true)
        let off = Kanban.columns(for: issues, in: states, closedState: done, defaultState: backlog, useDragOrder: false)
        for state in states {
            XCTAssertEqual(Set(on[state.id]?.map(\.id) ?? []), Set(off[state.id]?.map(\.id) ?? []))
        }
    }
}
