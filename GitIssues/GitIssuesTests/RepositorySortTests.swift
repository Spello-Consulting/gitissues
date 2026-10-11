//
//  RepositorySortTests.swift
//  GitIssuesTests
//
//  Created by Claude Code
//
//  Issue #106: the repository filter must sort by name, case-insensitively.
//

import XCTest
@testable import GitIssues

@MainActor
final class RepositorySortTests: XCTestCase {
    func testSortsCaseInsensitivelyByName() {
        let repos = ["zebra", "Apple", "banana", "Cherry", "apricot"].map { Fixture.repository(name: $0) }

        let sorted = repos.sortedByName().map(\.name)

        XCTAssertEqual(sorted, ["Apple", "apricot", "banana", "Cherry", "zebra"])
    }

    func testUppercaseNamesAreNotGroupedBeforeLowercase() {
        // A plain `<` string comparison puts every uppercase name before any lowercase one.
        let repos = ["alpha", "Beta", "gamma"].map { Fixture.repository(name: $0) }

        XCTAssertEqual(repos.sortedByName().map(\.name), ["alpha", "Beta", "gamma"])
    }

    func testSortsByRepoNameAcrossOwners() {
        let repos = [
            Fixture.repository(name: "beta", owner: "aaa"),
            Fixture.repository(name: "alpha", owner: "zzz")
        ]

        XCTAssertEqual(repos.sortedByName().map(\.fullName), ["zzz/alpha", "aaa/beta"])
    }

    func testSameNameFallsBackToFullName() {
        let repos = [
            Fixture.repository(name: "app", owner: "Zed"),
            Fixture.repository(name: "App", owner: "alice")
        ]

        XCTAssertEqual(repos.sortedByName().map(\.fullName), ["alice/App", "Zed/app"])
    }
}
