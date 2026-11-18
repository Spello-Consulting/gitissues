//
//  IssueSearchQuery.swift
//  GitIssues
//
//  Issue #109 — pure builder for the GitHub issue search string.
//

import Foundation

/// Builds the search string passed to GitHub's `search(type: ISSUE)` for the issue list.
enum IssueSearchQuery {
    /// - Parameters:
    ///   - states: Restrict to open or closed issues. `nil` (or both states) applies no state filter.
    ///   - allowReadOnly: When `false`, archived (read-only) repositories are excluded server-side.
    ///   - repositoryFullNames: Optional `owner/name` repositories to restrict to.
    ///   - visibility: Optional `public` / `private` repository visibility.
    ///
    /// `is:issue` is always included. `involves:@me` alone also matches pull requests, which the
    /// app discards after downloading them; asking GitHub to exclude them avoids fetching (and
    /// paging through) a large share of useless results.
    static func build(
        states: [IssueState]? = nil,
        allowReadOnly: Bool,
        repositoryFullNames: [String]? = nil,
        visibility: String? = nil
    ) -> String {
        var parts = ["involves:@me", "is:issue", "sort:updated-desc"]

        if !allowReadOnly {
            parts.append("archived:false")
        }

        // A single state narrows the search; both (or none) means "all".
        if let states, states.count == 1, let state = states.first {
            switch state {
            case .open: parts.append("is:open")
            case .closed: parts.append("is:closed")
            }
        }

        if let repos = repositoryFullNames, !repos.isEmpty {
            parts.append(repos.map { "repo:\($0)" }.joined(separator: " "))
        }

        if let visibility {
            parts.append("is:\(visibility)")
        }

        return parts.joined(separator: " ")
    }
}
