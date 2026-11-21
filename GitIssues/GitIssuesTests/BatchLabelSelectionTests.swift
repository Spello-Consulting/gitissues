//
//  BatchLabelSelectionTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #120: apply labels when multiple issues are selected.
//

import XCTest
@testable import GitIssues

@MainActor
final class BatchLabelSelectionTests: XCTestCase {
    private let repoA = Fixture.repository(name: "a")
    private let repoB = Fixture.repository(name: "b")

    private func issue(_ id: String, _ labels: [String], in repo: Repository? = nil) -> Issue {
        Fixture.issue(id: id, number: Int(id.dropFirst(2)) ?? 1, labels: labels, repository: repo ?? repoA)
    }

    // MARK: - unionLabels

    func testUnionDeduplicatesByCaseInsensitiveNameAndSorts() {
        let union = BatchLabelSelection.unionLabels([
            (repoA.id, [Fixture.label("docs"), Fixture.label("Bug")]),
            (repoB.id, [Fixture.label("bug"), Fixture.label("alpha")])
        ])

        XCTAssertEqual(union.map(\.name), ["alpha", "Bug", "docs"])
        XCTAssertEqual(union.first { $0.key == "bug" }?.repositoryIDs, [repoA.id, repoB.id])
        XCTAssertEqual(union.first { $0.key == "docs" }?.repositoryIDs, [repoA.id])
    }

    func testUnionExcludesKanbanLabels() {
        let union = BatchLabelSelection.unionLabels([(repoA.id, [Fixture.label("bug"), Fixture.label("kanban-Done")])])

        XCTAssertEqual(union.map(\.name), ["bug"])
    }

    // MARK: - state / intent

    func testStateNoneMixedAll() {
        let issues = [issue("I_1", ["bug"]), issue("I_2", ["Bug", "docs"]), issue("I_3", [])]

        XCTAssertEqual(BatchLabelSelection.state(ofLabelKey: "bug", in: issues), .mixed)
        XCTAssertEqual(BatchLabelSelection.state(ofLabelKey: "bug", in: Array(issues.prefix(2))), .all)
        XCTAssertEqual(BatchLabelSelection.state(ofLabelKey: "other", in: issues), .none)
    }

    func testStateIgnoresKanbanLabels() {
        XCTAssertEqual(BatchLabelSelection.state(ofLabelKey: "kanban-done", in: [issue("I_1", ["kanban-Done"])]), .none)
    }

    func testNextIntentCycles() {
        // none → add → none
        XCTAssertEqual(BatchLabelSelection.nextIntent(current: nil, initial: .none), .add)
        XCTAssertNil(BatchLabelSelection.nextIntent(current: .add, initial: .none))
        // all → remove → all
        XCTAssertEqual(BatchLabelSelection.nextIntent(current: nil, initial: .all), .remove)
        XCTAssertNil(BatchLabelSelection.nextIntent(current: .remove, initial: .all))
        // mixed → add → remove → mixed
        XCTAssertEqual(BatchLabelSelection.nextIntent(current: nil, initial: .mixed), .add)
        XCTAssertEqual(BatchLabelSelection.nextIntent(current: .add, initial: .mixed), .remove)
        XCTAssertNil(BatchLabelSelection.nextIntent(current: .remove, initial: .mixed))
    }

    func testDisplayState() {
        XCTAssertEqual(BatchLabelSelection.displayState(initial: .mixed, intent: nil), .mixed)
        XCTAssertEqual(BatchLabelSelection.displayState(initial: .mixed, intent: .add), .all)
        XCTAssertEqual(BatchLabelSelection.displayState(initial: .all, intent: .remove), .none)
    }

    // MARK: - plan

    func testAddSkipsIssuesThatAlreadyHaveTheLabel() {
        let issues = [issue("I_1", ["bug"]), issue("I_2", [])]
        let plan = BatchLabelSelection.plan(issues: issues, intents: ["bug": .add])

        XCTAssertEqual(plan.map(\.issue.id), ["I_2"])
        XCTAssertEqual(plan.first?.add, ["bug"])
    }

    func testRemoveSkipsIssuesThatLackTheLabel() {
        let issues = [issue("I_1", ["Bug"]), issue("I_2", [])]
        let plan = BatchLabelSelection.plan(issues: issues, intents: ["bug": .remove])

        XCTAssertEqual(plan.map(\.issue.id), ["I_1"])
        XCTAssertEqual(plan.first?.remove, ["bug"])
    }

    func testUntouchedLabelsProduceNoChanges() {
        let plan = BatchLabelSelection.plan(issues: [issue("I_1", ["bug"]), issue("I_2", [])], intents: [:])

        XCTAssertTrue(plan.isEmpty)
    }

    func testKanbanLabelsAreNeverRemoved() {
        let plan = BatchLabelSelection.plan(issues: [issue("I_1", ["kanban-Done"])], intents: ["kanban-done": .remove])

        XCTAssertTrue(plan.isEmpty)
    }

    func testIssuesNeedingNoChangeAreOmitted() {
        let issues = [issue("I_1", ["bug"]), issue("I_2", ["bug"])]

        XCTAssertTrue(BatchLabelSelection.plan(issues: issues, intents: ["bug": .add]).isEmpty)
    }

    // MARK: - missingLabels / resolve

    func testMissingLabelsOnlyForReposLackingTheLabel() {
        let issues = [issue("I_1", [], in: repoA), issue("I_2", [], in: repoB), issue("I_3", [], in: repoB)]
        let repoLabels = [repoA.id: [Fixture.label("bug")], repoB.id: [Fixture.label("docs")]]
        let union = BatchLabelSelection.unionLabels([(repoA.id, repoLabels[repoA.id]!), (repoB.id, repoLabels[repoB.id]!)])
        let plan = BatchLabelSelection.plan(issues: issues, intents: ["bug": .add])

        let missing = BatchLabelSelection.missingLabels(plan: plan, repoLabels: repoLabels, union: union)

        // Created once in repo B, even though two issues there need it; not in repo A.
        XCTAssertEqual(missing, [RepoLabelCreation(repository: repoB, name: "bug", color: "ffffff")])
    }

    func testMissingLabelsIgnoresRemovals() {
        let issues = [issue("I_1", ["bug"], in: repoA)]
        let plan = BatchLabelSelection.plan(issues: issues, intents: ["bug": .remove])

        XCTAssertTrue(BatchLabelSelection.missingLabels(plan: plan, repoLabels: [repoA.id: []], union: []).isEmpty)
    }

    func testResolveUsesRepoLabelIDsForAddsAndIssueIDsForRemovals() {
        let repoBBug = GitIssues.Label(id: "b-bug", name: "Bug", color: "ff0000")
        let change = IssueLabelChange(issue: issue("I_1", ["docs"], in: repoB), add: ["bug"], remove: ["docs"])

        let resolved = BatchLabelSelection.resolve(change, repoLabels: [repoB.id: [repoBBug]])

        XCTAssertEqual(resolved.add.map(\.id), ["b-bug"])
        XCTAssertEqual(resolved.removeIDs, ["l-docs"])
    }

    func testResolveDropsAdditionsTheRepoStillLacks() {
        let change = IssueLabelChange(issue: issue("I_1", [], in: repoA), add: ["bug"], remove: [])

        XCTAssertTrue(BatchLabelSelection.resolve(change, repoLabels: [repoA.id: []]).add.isEmpty)
    }

    func testResultingLabelsKeepKanbanAndApplyChanges() {
        let current = [Fixture.label("kanban-Done"), Fixture.label("bug")]
        let result = BatchLabelSelection.resultingLabels(current: current, add: [Fixture.label("docs")], removeIDs: ["l-bug"])

        XCTAssertEqual(result.map(\.name), ["kanban-Done", "docs"])
    }
}
