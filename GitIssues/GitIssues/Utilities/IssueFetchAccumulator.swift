//
//  IssueFetchAccumulator.swift
//  GitIssues
//
//  Issue #109 — collects issues from several concurrently-paged searches.
//

import Foundation

/// Collects pages of issues arriving from concurrent search streams (open and closed) and exposes
/// the combined list at any point, so the UI can show partial results while paging continues.
///
/// Issues are de-duplicated by id. GitHub's search results can shift while paging (an issue
/// updated mid-fetch can appear on two pages, or move between the open and closed streams), so when
/// an id is seen twice the copy with the newer `updatedAt` wins. The snapshot is ordered newest-updated
/// first, matching the `sort:updated-desc` order of an un-split search.
final class IssueFetchAccumulator {
    private var byID: [String: Issue] = [:]

    /// Adds a page of issues.
    func add(_ page: [Issue]) {
        for issue in page {
            if let existing = byID[issue.id], existing.updatedAt > issue.updatedAt { continue }
            byID[issue.id] = issue
        }
    }

    /// Everything collected so far, newest-updated first (ties broken by id for stable output).
    var snapshot: [Issue] {
        byID.values.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }

    var count: Int { byID.count }
}
