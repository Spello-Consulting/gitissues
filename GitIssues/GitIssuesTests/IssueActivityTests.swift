//
//  IssueActivityTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #102: GitHub activity log in the issue detail panel.
//

import XCTest
@testable import GitIssues

@MainActor
final class IssueActivityTests: XCTestCase {
    private func decode(_ json: String) throws -> [IssueActivity] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(IssueActivityResponse.self, from: Data(json.utf8))
        return response.repository.issue.timelineItems.nodes.compactMap { $0.toActivity() }
    }

    func testDecodesTimelineNodesFromGitHubResponse() throws {
        let json = """
        {"repository":{"issue":{"timelineItems":{"nodes":[
          {"__typename":"LabeledEvent","id":"1","createdAt":"2026-09-27T07:14:04Z",
           "actor":{"login":"nick","avatarUrl":"https://example.com/a.png"},
           "label":{"id":"L1","name":"bug","color":"d73a4a"}},
          {"__typename":"CrossReferencedEvent","id":"2","createdAt":"2026-10-11T07:23:43Z",
           "actor":{"login":"nick","avatarUrl":null},
           "source":{"__typename":"PullRequest","number":107,"title":"Fix issues",
                     "repository":{"nameWithOwner":"org/repo"}}},
          {"__typename":"ClosedEvent","id":"3","createdAt":"2026-10-11T07:33:10Z",
           "actor":{"login":"nick","avatarUrl":null},"stateReason":"COMPLETED"},
          {"__typename":"AssignedEvent","id":"4","createdAt":"2026-10-11T07:34:00Z",
           "actor":{"login":"nick","avatarUrl":null},"assignee":{"login":"alice"}},
          {"__typename":"SomethingNew","id":"5","createdAt":"2026-10-11T07:35:00Z"}
        ]}}}}
        """

        let events = try decode(json)

        XCTAssertEqual(events.count, 4, "Unknown event types are skipped")
        XCTAssertEqual(events[0].kind, .labeled(Label(id: "L1", name: "bug", color: "d73a4a")))
        XCTAssertEqual(events[0].actor?.login, "nick")
        XCTAssertEqual(events[1].phrase, "mentioned this in pull request org/repo#107 Fix issues")
        XCTAssertEqual(events[2].phrase, "closed this as completed")
        XCTAssertEqual(events[3].phrase, "assigned alice")
    }

    func testPhrases() {
        func phrase(_ kind: IssueActivity.Kind) -> String {
            IssueActivity(id: "x", actor: nil, createdAt: Fixture.epoch, kind: kind).phrase
        }

        XCTAssertEqual(phrase(.closed(reason: "NOT_PLANNED")), "closed this as not planned")
        XCTAssertEqual(phrase(.closed(reason: nil)), "closed this")
        XCTAssertEqual(phrase(.reopened), "reopened this")
        XCTAssertEqual(phrase(.renamed(from: "A", to: "B")), "changed the title from “A” to “B”")
        XCTAssertEqual(phrase(.milestoned(title: "v2")), "added this to the v2 milestone")
        XCTAssertEqual(phrase(.locked(reason: "TOO_HEATED")), "locked this conversation as too heated")
        XCTAssertEqual(phrase(.unlocked), "unlocked this conversation")
    }

    func testKanbanLabelEventsAreFlagged() {
        let kanban = IssueActivity(id: "1", actor: nil, createdAt: Fixture.epoch, kind: .labeled(Fixture.label("kanban-Done")))
        let normal = IssueActivity(id: "2", actor: nil, createdAt: Fixture.epoch, kind: .labeled(Fixture.label("bug")))
        let closed = IssueActivity(id: "3", actor: nil, createdAt: Fixture.epoch, kind: .closed(reason: nil))

        XCTAssertTrue(kanban.isKanbanLabelEvent)
        XCTAssertFalse(normal.isKanbanLabelEvent)
        XCTAssertFalse(closed.isKanbanLabelEvent)
    }

    func testMergeInterleavesChronologicallyAndDropsKanbanEvents() {
        let t0 = Fixture.epoch
        let comments = [
            Comment(id: "c1", body: "first", author: nil, createdAt: t0.addingTimeInterval(10), updatedAt: t0),
            Comment(id: "c2", body: "second", author: nil, createdAt: t0.addingTimeInterval(30), updatedAt: t0)
        ]
        let activity = [
            IssueActivity(id: "a1", actor: nil, createdAt: t0.addingTimeInterval(20), kind: .reopened),
            IssueActivity(id: "a2", actor: nil, createdAt: t0.addingTimeInterval(25), kind: .labeled(Fixture.label("kanban-Done"))),
            IssueActivity(id: "a3", actor: nil, createdAt: t0.addingTimeInterval(5), kind: .closed(reason: nil))
        ]

        let merged = ConversationEntry.merge(comments: comments, activity: activity)

        XCTAssertEqual(merged.map(\.id), ["activity-a3", "comment-c1", "activity-a1", "comment-c2"])
    }

    func testMergeWithNoActivityKeepsCommentsInOrder() {
        let comments = [
            Comment(id: "c1", body: "", author: nil, createdAt: Fixture.epoch, updatedAt: Fixture.epoch),
            Comment(id: "c2", body: "", author: nil, createdAt: Fixture.epoch.addingTimeInterval(1), updatedAt: Fixture.epoch)
        ]

        let merged = ConversationEntry.merge(comments: comments, activity: [])

        XCTAssertEqual(merged.map(\.id), ["comment-c1", "comment-c2"])
    }

    func testCommentComesBeforeActivityAtSameInstant() {
        let comment = Comment(id: "c", body: "", author: nil, createdAt: Fixture.epoch, updatedAt: Fixture.epoch)
        let event = IssueActivity(id: "a", actor: nil, createdAt: Fixture.epoch, kind: .reopened)

        let merged = ConversationEntry.merge(comments: [comment], activity: [event])

        XCTAssertEqual(merged.map(\.id), ["comment-c", "activity-a"])
    }
}

// MARK: - Resilience

@MainActor
final class IssueActivityDecodingResilienceTests: XCTestCase {
    func testNullAndMalformedNodesAreSkippedNotFatal() throws {
        let json = """
        {"repository":{"issue":{"timelineItems":{"nodes":[
          {"__typename":"ReopenedEvent","id":"1","createdAt":"2026-10-11T07:23:43Z","actor":{"login":"nick","avatarUrl":null}},
          null,
          {"__typename":"LabeledEvent","id":"2","createdAt":"not a date","actor":{"login":"nick"}},
          {"__typename":"ClosedEvent","id":"3","createdAt":"2026-10-11T07:33:10Z","actor":null,"stateReason":"COMPLETED"}
        ]}}}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let response = try decoder.decode(IssueActivityResponse.self, from: Data(json.utf8))
        let events = response.repository.issue.timelineItems.nodes.compactMap { $0.toActivity() }

        XCTAssertEqual(events.map(\.id), ["1", "3"])
        XCTAssertNil(events[1].actor, "A deleted user (null actor) is shown as 'Someone', not an error")
    }
}

@MainActor
final class IssueActivityQueryScopeTests: XCTestCase {
    /// The app's OAuth token only has `repo` + `read:user`. Selecting `Organization.login` needs
    /// `read:org` and makes GitHub reject the entire query for such tokens.
    func testActivityQueryDoesNotRequireReadOrgScope() {
        XCTAssertFalse(GraphQLQueries.issueActivityQuery.contains("on Organization"))
    }
}
