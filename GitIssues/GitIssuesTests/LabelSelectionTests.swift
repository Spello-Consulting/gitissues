//
//  LabelSelectionTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #97: add/remove labels from the context-menu dialog.
//

import XCTest
@testable import GitIssues

@MainActor
final class LabelSelectionTests: XCTestCase {
    private let bug = Fixture.label("bug")
    private let docs = Fixture.label("docs")
    private let wip = Fixture.label("kanban-In Progress")

    func testSelectingNewLabelAddsIt() {
        let changes = LabelSelection.changes(current: [bug], selectedIds: [bug.id, docs.id])

        XCTAssertEqual(changes.add, [docs.id])
        XCTAssertEqual(changes.remove, [])
    }

    func testUnselectingExistingLabelRemovesIt() {
        let changes = LabelSelection.changes(current: [bug, docs], selectedIds: [docs.id])

        XCTAssertEqual(changes.add, [])
        XCTAssertEqual(changes.remove, [bug.id])
    }

    func testNoChangeProducesNoOperations() {
        let changes = LabelSelection.changes(current: [bug], selectedIds: [bug.id])

        XCTAssertTrue(changes.add.isEmpty)
        XCTAssertTrue(changes.remove.isEmpty)
    }

    func testKanbanLabelsAreNeverRemoved() {
        // The dialog hides Kanban labels, so they're absent from the selection.
        let changes = LabelSelection.changes(current: [bug, wip], selectedIds: [bug.id])

        XCTAssertEqual(changes.remove, [])
    }

    func testResultingLabelsKeepKanbanLabels() {
        let result = LabelSelection.resulting(current: [bug, wip], selected: [docs])

        XCTAssertEqual(result.map(\.name), ["kanban-In Progress", "docs"])
    }
}
