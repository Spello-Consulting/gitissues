//
//  DefaultRepositoryTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #99: the New Issue form defaults to the last-used repository.
//

import XCTest
@testable import GitIssues

@MainActor
final class DefaultRepositoryTests: XCTestCase {
    private let repos = [
        Fixture.repository(name: "alpha"),
        Fixture.repository(name: "beta")
    ]

    func testNoLastUsedRepositoryLeavesFieldBlank() {
        XCTAssertNil(IssueFormViewModel.defaultRepositoryId(lastUsed: nil, available: repos))
    }

    func testLastUsedRepositoryIsPreselected() {
        let id = repos[1].id

        XCTAssertEqual(IssueFormViewModel.defaultRepositoryId(lastUsed: id, available: repos), id)
    }

    func testLastUsedRepositoryNoLongerAvailableLeavesFieldBlank() {
        // e.g. the repo became read-only/archived, or isn't in the writable list.
        XCTAssertNil(IssueFormViewModel.defaultRepositoryId(lastUsed: "gone", available: repos))
    }
}
