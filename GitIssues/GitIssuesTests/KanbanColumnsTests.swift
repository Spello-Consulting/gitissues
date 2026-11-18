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
}
