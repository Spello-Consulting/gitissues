//
//  TestSupport.swift
//  GitIssuesTests
//
//  Created by Claude Code
//

import Foundation
@testable import GitIssues

/// Builders for model values used across the unit tests.
enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func repository(name: String, owner: String = "owner", id: String? = nil) -> Repository {
        Repository(
            id: id ?? "\(owner)/\(name)",
            name: name,
            owner: User(id: "u-\(owner)", login: owner, avatarUrl: nil),
            isPrivate: false
        )
    }

    static func label(_ name: String) -> GitIssues.Label {
        GitIssues.Label(id: "l-\(name)", name: name, color: "ffffff")
    }

    static func issue(
        id: String = "I_1",
        title: String = "Title",
        state: IssueState = .open,
        labels: [String] = [],
        updatedAt: Date = Fixture.epoch,
        repository: Repository = Fixture.repository(name: "repo")
    ) -> Issue {
        Issue(
            id: id,
            number: 1,
            title: title,
            body: nil,
            state: state,
            createdAt: Fixture.epoch,
            updatedAt: updatedAt,
            repository: repository,
            labels: labels.map(label),
            assignees: [],
            author: nil
        )
    }
}
