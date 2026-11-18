//
//  RepositoryLabelCache.swift
//  GitIssues
//
//  Issue #109 — avoids re-listing a repository's labels on every Kanban move.
//

import Foundation

/// In-memory cache of each repository's labels, keyed by repository id then lowercased label name.
///
/// A Kanban move needs the id of the target `kanban-<Status>` label. Listing every label in the
/// repository on every move costs a round trip (~0.4 s); this keeps the result for the session.
/// The cache can go stale (a label deleted or created on github.com), so callers invalidate a
/// repository when a write that used a cached label fails and retry with fresh data.
struct RepositoryLabelCache {
    private var labels: [String: [String: Label]] = [:]

    /// Whether the repository's labels have been loaded.
    func isPopulated(repositoryID: String) -> Bool {
        labels[repositoryID] != nil
    }

    /// The cached label named `name` (case-insensitive), if any.
    func label(named name: String, repositoryID: String) -> Label? {
        labels[repositoryID]?[name.lowercased()]
    }

    /// Replaces the repository's cached labels with a freshly fetched full list.
    mutating func store(_ all: [Label], repositoryID: String) {
        var byName: [String: Label] = [:]
        for label in all where byName[label.name.lowercased()] == nil {
            byName[label.name.lowercased()] = label
        }
        labels[repositoryID] = byName
    }

    /// Adds one label (e.g. just created) to an already-populated repository entry.
    mutating func insert(_ label: Label, repositoryID: String) {
        guard labels[repositoryID] != nil else { return }
        labels[repositoryID]?[label.name.lowercased()] = label
    }

    /// Forgets a repository's labels.
    /// - Returns: `true` if there was cached data to drop (so a retry with fresh data is worthwhile).
    @discardableResult
    mutating func invalidate(repositoryID: String) -> Bool {
        labels.removeValue(forKey: repositoryID) != nil
    }
}
