//
//  IssueSearchQueryTests.swift
//  GitIssuesTests
//
//  Issue #109: the list search must exclude pull requests server-side and split by state.
//

import XCTest
@testable import GitIssues

@MainActor
final class IssueSearchQueryTests: XCTestCase {
    private func terms(_ query: String) -> Set<String> {
        Set(query.split(separator: " ").map(String.init))
    }

    func testAlwaysRestrictsToIssuesInvolvingViewer() {
        let query = IssueSearchQuery.build(allowReadOnly: true)
        XCTAssertTrue(terms(query).isSuperset(of: ["involves:@me", "is:issue", "sort:updated-desc"]))
    }

    func testReadOnlyReposExcludedUnlessAllowed() {
        XCTAssertTrue(terms(IssueSearchQuery.build(allowReadOnly: false)).contains("archived:false"))
        XCTAssertFalse(terms(IssueSearchQuery.build(allowReadOnly: true)).contains("archived:false"))
    }

    func testSingleStateAddsStateQualifier() {
        XCTAssertTrue(terms(IssueSearchQuery.build(states: [.open], allowReadOnly: true)).contains("is:open"))
        XCTAssertTrue(terms(IssueSearchQuery.build(states: [.closed], allowReadOnly: true)).contains("is:closed"))
    }

    func testNoStateOrBothStatesAddsNoStateQualifier() {
        for states in [nil, [IssueState.open, .closed]] as [[IssueState]?] {
            let t = terms(IssueSearchQuery.build(states: states, allowReadOnly: true))
            XCTAssertFalse(t.contains("is:open"))
            XCTAssertFalse(t.contains("is:closed"))
        }
    }

    func testRepositoryAndVisibilityFilters() {
        let query = IssueSearchQuery.build(
            allowReadOnly: true,
            repositoryFullNames: ["a/one", "b/two"],
            visibility: "private"
        )
        XCTAssertTrue(terms(query).isSuperset(of: ["repo:a/one", "repo:b/two", "is:private"]))
    }

    func testUpdatedSinceAddsUTCTimestampQualifier() {
        // 2026-11-18T14:00:00Z
        let date = Date(timeIntervalSince1970: 1_795_010_400)
        let query = IssueSearchQuery.build(allowReadOnly: true, updatedSince: date)
        XCTAssertTrue(terms(query).contains("updated:>=\(IssueSearchQuery.timestamp(date))"))
        XCTAssertEqual(IssueSearchQuery.timestamp(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00Z")
        XCTAssertFalse(terms(IssueSearchQuery.build(allowReadOnly: true)).contains { $0.hasPrefix("updated:") })
    }
}
