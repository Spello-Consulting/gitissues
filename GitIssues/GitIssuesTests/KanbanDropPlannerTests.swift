//
//  KanbanDropPlannerTests.swift
//  GitIssuesTests
//
//  Issue #119: dropping cards must put them exactly where they were dropped, even beside unkeyed
//  cards or between cards that share an order key. Most tests apply the plan and re-run the real
//  column ordering (`Kanban.columns`) to check the displayed result.
//

import XCTest
@testable import GitIssues

@MainActor
final class KanbanDropPlannerTests: XCTestCase {
    private let backlog = KanbanState(name: "Backlog", isClosed: false)
    private let done = KanbanState(name: "Done", isClosed: true)

    private func marker(_ key: String) -> String { "<!-- gitissues:order=\(key) -->" }

    private func issue(_ id: String, number: Int, key: String?) -> Issue {
        Fixture.issue(id: id, number: number, body: key.map(marker))
    }

    /// The displayed order of `issues` (already in selected-sort order) as ids.
    private func displayed(_ issues: [Issue]) -> [Issue] {
        Kanban.columns(for: issues, in: [backlog], closedState: done, defaultState: backlog)[backlog.id] ?? []
    }

    /// Drops `count` new cards at `index` of the displayed column, applies the plan to the issues
    /// and returns the new displayed ids.
    private func apply(
        to incoming: [Issue], at index: Int, count: Int
    ) -> (before: [String], after: [String], moved: [String], plan: KanbanDropPlan) {
        let column = displayed(incoming)
        let plan = KanbanDropPlanner.plan(column: column, index: index, count: count)
        XCTAssertEqual(plan.keys.count, count)

        var updated: [Issue] = incoming.map { original in
            guard let rekey = plan.rekeys.first(where: { $0.issueID == original.id }) else { return original }
            return issue(original.id, number: original.number, key: rekey.key)
        }
        let moved = (0..<count).map { "M\($0)" }
        for (i, key) in plan.keys.enumerated() {
            updated.append(issue(moved[i], number: 1000 + i, key: key))
        }
        return (column.map(\.id), displayed(updated).map(\.id), moved, plan)
    }

    /// Asserts the dropped cards land at `index` and everything else keeps its relative order.
    private func assertDropLandsAtIndex(
        _ incoming: [Issue], _ index: Int, _ count: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let r = apply(to: incoming, at: index, count: count)
        let expected = Array(r.before[..<index]) + r.moved + Array(r.before[index...])
        XCTAssertEqual(r.after, expected, "drop of \(count) at \(index)", file: file, line: line)
        XCTAssertEqual(Set(r.plan.keys).count, count, "Dropped keys are distinct", file: file, line: line)
    }

    // MARK: - Individual cases

    func testEmptyColumnNeedsNoRekeys() {
        let plan = KanbanDropPlanner.plan(column: [], index: 0, count: 1)
        XCTAssertEqual(plan.keys, [FractionalIndex.keyBetween(nil, nil)])
        XCTAssertTrue(plan.rekeys.isEmpty)
    }

    func testBetweenDistinctKeysNeedsNoRekeys() {
        let column = [issue("a", number: 3, key: "A"), issue("b", number: 2, key: "M"), issue("c", number: 1, key: "Z")]
        let plan = KanbanDropPlanner.plan(column: column, index: 1, count: 1)
        XCTAssertTrue(plan.rekeys.isEmpty)
        XCTAssertGreaterThan(plan.keys[0], "A")
        XCTAssertLessThan(plan.keys[0], "M")
    }

    func testDropBetweenTiedKeysRekeysOnlyTheTieMembersBelowTheDropPoint() {
        // Keys V V V, then a later distinct key. Drop between the 1st and 2nd V.
        let incoming = [
            issue("v1", number: 9, key: "V"), issue("v2", number: 8, key: "V"),
            issue("v3", number: 7, key: "V"), issue("l1", number: 6, key: "l")
        ]
        let r = apply(to: incoming, at: 1, count: 1)
        XCTAssertEqual(Set(r.plan.rekeys.map(\.issueID)), ["v2", "v3"], "Members above the drop keep their key")
        XCTAssertEqual(r.after, ["v1", "M0", "v2", "v3", "l1"])
    }

    func testDropBelowUnkeyedCardRekeysTheUnkeyedRunAboveTheDropPoint() {
        let incoming = [
            issue("k", number: 9, key: "V"),
            issue("u1", number: 8, key: nil), issue("u2", number: 7, key: nil), issue("u3", number: 6, key: nil)
        ]
        let r = apply(to: incoming, at: 3, count: 1)
        XCTAssertEqual(Set(r.plan.rekeys.map(\.issueID)), ["u1", "u2"], "Only the run above the drop point is keyed")
        XCTAssertEqual(r.after, ["k", "u1", "u2", "M0", "u3"])
    }

    func testDropAtTopOfUnkeyedColumnNeedsNoRekeys() {
        let incoming = [issue("u1", number: 3, key: nil), issue("u2", number: 2, key: nil)]
        let r = apply(to: incoming, at: 0, count: 1)
        XCTAssertTrue(r.plan.rekeys.isEmpty)
        XCTAssertEqual(r.after, ["M0", "u1", "u2"])
    }

    func testAppendAfterKeyedCardsWithNoUnkeyedNeedsNoRekeys() {
        let incoming = [issue("a", number: 2, key: "V"), issue("b", number: 1, key: "V")]
        let r = apply(to: incoming, at: 2, count: 2)
        XCTAssertTrue(r.plan.rekeys.isEmpty)
        XCTAssertEqual(r.after, ["a", "b", "M0", "M1"])
    }

    // MARK: - Exhaustive: every drop position, 1–3 cards

    private func assertEveryDropPosition(_ incoming: [Issue], file: StaticString = #filePath, line: UInt = #line) {
        let size = displayed(incoming).count
        for count in 1...3 {
            for index in 0...size {
                assertDropLandsAtIndex(incoming, index, count, file: file, line: line)
            }
        }
    }

    /// The Closed column from the #119 screenshot, in Issue # (High to Low) order.
    func testEveryDropPositionInTheIssue119ClosedColumn() {
        let keys: [(Int, String)] = [
            (92, "V"), (93, "V"), (99, "V"), (106, "V"), (109, "V"),
            (94, "l"), (101, "l"), (105, "l"),
            (96, "t"), (102, "t"), (103, "t"),
            (104, "x"), (95, "z"), (97, "z"), (100, "zl")
        ]
        let incoming = SortOption.numberDesc.sort(keys.map { issue("I\($0.0)", number: $0.0, key: $0.1) })
        assertEveryDropPosition(incoming)
    }

    func testEveryDropPositionInAColumnWithNoKeys() {
        let incoming = (1...6).reversed().map { issue("u\($0)", number: $0, key: nil) }
        assertEveryDropPosition(incoming)
    }

    func testEveryDropPositionInAMixedColumn() {
        let incoming = [
            issue("a", number: 9, key: "V"), issue("b", number: 8, key: "V"), issue("c", number: 7, key: "l"),
            issue("u1", number: 6, key: nil), issue("u2", number: 5, key: nil), issue("u3", number: 4, key: nil)
        ]
        assertEveryDropPosition(incoming)
    }

    func testSelectedSortOtherThanNumberStillHolds() {
        // Same tie group, but incoming order is Issue # ascending.
        let incoming = SortOption.numberAsc.sort((1...5).map { issue("v\($0)", number: $0, key: "V") })
        assertEveryDropPosition(incoming)
    }
}
