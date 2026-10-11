//
//  KanbanPlacementTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #103: a closed issue always lands in the closed column, whatever kanban label it has.
//

import XCTest
@testable import GitIssues

@MainActor
final class KanbanPlacementTests: XCTestCase {
    private let backlog = KanbanState(name: "Backlog", isClosed: false)
    private let inProgress = KanbanState(name: "In Progress", isClosed: false)
    private let done = KanbanState(name: "Done", isClosed: true)
    private var states: [KanbanState] { [backlog, inProgress, done] }

    private func column(for issue: Issue) -> KanbanState {
        Kanban.state(for: issue, in: states, closedState: done, defaultState: backlog)
    }

    func testClosedIssueWithKanbanLabelGoesToClosedColumn() {
        let issue = Fixture.issue(state: .closed, labels: ["kanban-In Progress"])

        XCTAssertEqual(column(for: issue), done)
    }

    func testClosedIssueWithoutLabelGoesToClosedColumn() {
        XCTAssertEqual(column(for: Fixture.issue(state: .closed)), done)
    }

    func testClosedIssueWithConflictingLabelsGoesToClosedColumn() {
        let issue = Fixture.issue(state: .closed, labels: ["kanban-Backlog", "kanban-In Progress"])

        XCTAssertEqual(column(for: issue), done)
    }

    func testOpenIssueWithSingleLabelGoesToThatColumn() {
        let issue = Fixture.issue(state: .open, labels: ["bug", "Kanban-in progress"])

        XCTAssertEqual(column(for: issue), inProgress)
    }

    func testOpenIssueWithoutLabelGoesToDefaultColumn() {
        XCTAssertEqual(column(for: Fixture.issue(state: .open, labels: ["bug"])), backlog)
    }

    func testOpenIssueWithMultipleLabelsGoesToDefaultColumn() {
        let issue = Fixture.issue(state: .open, labels: ["kanban-Backlog", "kanban-In Progress"])

        XCTAssertEqual(column(for: issue), backlog)
    }

    func testUnconfiguredKanbanLabelIsIgnored() {
        let open = Fixture.issue(state: .open, labels: ["kanban-Someone Elses Column"])
        let closed = Fixture.issue(state: .closed, labels: ["kanban-Someone Elses Column"])

        XCTAssertEqual(column(for: open), backlog)
        XCTAssertEqual(column(for: closed), done)
    }
}
