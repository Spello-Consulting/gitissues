//
//  KanbanMovePlannerTests.swift
//  GitIssuesTests
//
//  Issue #109: a Kanban move / close is written as one updateIssue(labelIds:) mutation, so the
//  computed label set must keep unrelated labels and never drop any.
//

import XCTest
@testable import GitIssues

@MainActor
final class KanbanMovePlannerTests: XCTestCase {
    private let managed: Set<String> = ["kanban-in progress", "kanban-review"]

    private func labels(_ names: String...) -> [GitIssues.Label] { names.map(Fixture.label) }

    func testSwapsManagedLabelForTargetKeepingOthers() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("bug", "kanban-In Progress", "docs"),
            managedLabelNames: managed,
            adding: Fixture.label("kanban-Review")
        )
        XCTAssertEqual(ids, ["l-bug", "l-docs", "l-kanban-Review"])
    }

    func testManagedMatchIsCaseInsensitive() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("KANBAN-REVIEW", "bug"),
            managedLabelNames: managed,
            adding: nil
        )
        XCTAssertEqual(ids, ["l-bug"])
    }

    func testMoveToClutterFreeColumnRemovesManagedLabelOnly() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("kanban-Review"),
            managedLabelNames: managed,
            adding: nil
        )
        XCTAssertEqual(ids, [], "An empty list clears the labels — distinct from nil (leave untouched)")
    }

    func testNilWhenLabelSetUnchangedSoLabelsAreNotSent() {
        // Reordering inside a column: already has the target label, nothing managed to remove.
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("bug", "kanban-Review"),
            managedLabelNames: managed,
            adding: Fixture.label("kanban-Review")
        )
        XCTAssertNil(ids)
    }

    func testNilWhenNoLabelsAndNothingToAdd() {
        XCTAssertNil(KanbanMovePlanner.labelUpdate(currentLabels: [], managedLabelNames: managed, adding: nil))
    }

    func testAddsTargetToIssueWithNoKanbanLabel() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("bug"),
            managedLabelNames: managed,
            adding: Fixture.label("kanban-Review")
        )
        XCTAssertEqual(ids, ["l-bug", "l-kanban-Review"])
    }

    func testTargetNotDuplicatedWhenAlreadyPresentAlongsideOtherManagedLabel() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("kanban-In Progress", "kanban-Review"),
            managedLabelNames: managed,
            adding: Fixture.label("kanban-Review")
        )
        // Both managed labels are stripped, then the target is added back exactly once.
        XCTAssertEqual(ids, ["l-kanban-Review"])
    }

    func testOtherUsersKanbanLabelsAreKept() {
        let ids = KanbanMovePlanner.labelUpdate(
            currentLabels: labels("kanban-Someone Elses", "kanban-Review"),
            managedLabelNames: managed,
            adding: nil
        )
        XCTAssertEqual(ids, ["l-kanban-Someone Elses"])
    }
}
