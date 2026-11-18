//
//  IssueSyncMerger.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

/// A local edit that was applied to the issues cache and that a sync response may not reflect yet.
struct PendingIssueUpdate {
    let issue: Issue
    let appliedAt: Date
}

/// Pure merge logic for reconciling a freshly-fetched issue list with local edits.
///
/// Background syncs fetch the whole issue list, which takes a while. If the user saves an edit
/// while a sync is in flight, the sync response predates the edit and would overwrite the freshly
/// updated issue with its old title/state/body. GitHub's search index is also eventually
/// consistent, so even a sync that starts after the edit can briefly return the old values.
enum IssueSyncMerger {
    /// How long a local edit is protected from being overwritten by a sync response that still
    /// shows older data. After this the server copy always wins.
    static let gracePeriod: TimeInterval = 30

    /// Builds the list to publish from `incoming` plus the local mutations that may have raced ahead
    /// of the fetch: re-injects unconfirmed insertions, hides pending deletions, and keeps
    /// locally-edited issues the response doesn't reflect yet (see `merge`).
    ///
    /// - Parameter isComplete: `true` when `incoming` is the full result of a fetch. Only then can an
    ///   issue's *absence* be read as "the server confirms the deletion", so pending deletions and
    ///   insertions are only acknowledged (and dropped) for complete results. A partial result (some
    ///   pages of a still-running fetch) leaves them untouched so a deleted issue can't flash back and
    ///   an unconfirmed new issue isn't forgotten.
    static func reconcile(
        incoming: [Issue],
        pendingUpdates: inout [String: PendingIssueUpdate],
        pendingDeletions: inout Set<String>,
        pendingInsertions: inout [Issue],
        fetchStartedAt: Date,
        isComplete: Bool,
        now: Date = Date()
    ) -> [Issue] {
        let incomingIDs = Set(incoming.map { $0.id })

        if isComplete {
            // Confirmed absent → deletion acknowledged, stop filtering
            pendingDeletions = pendingDeletions.filter { incomingIDs.contains($0) }
            // Confirmed present → insertion acknowledged, stop prepending
            pendingInsertions = pendingInsertions.filter { !incomingIDs.contains($0.id) }
        }

        let merged = merge(
            incoming: incoming,
            pending: &pendingUpdates,
            fetchStartedAt: fetchStartedAt,
            now: now
        )
        let visible = merged.filter { !pendingDeletions.contains($0.id) }
        let unconfirmedInsertions = pendingInsertions.filter { !incomingIDs.contains($0.id) }
        return unconfirmedInsertions + visible
    }

    /// Returns `incoming` with any issue that has a still-pending local edit replaced by the local
    /// copy. Updates are dropped from `pending` once the server has caught up (or the grace period
    /// has expired).
    ///
    /// A local copy is kept when either
    /// - the fetch started before the edit was applied (the response cannot contain it), or
    /// - the server's `updatedAt` is older than the local copy's (the server hasn't caught up).
    static func merge(
        incoming: [Issue],
        pending: inout [String: PendingIssueUpdate],
        fetchStartedAt: Date,
        now: Date = Date()
    ) -> [Issue] {
        pending = pending.filter { now.timeIntervalSince($0.value.appliedAt) < gracePeriod }
        guard !pending.isEmpty else { return incoming }

        return incoming.map { fetched in
            guard let update = pending[fetched.id] else { return fetched }

            let fetchPredatesEdit = fetchStartedAt <= update.appliedAt
            let serverIsBehind = fetched.updatedAt < update.issue.updatedAt
            if fetchPredatesEdit || serverIsBehind {
                return update.issue
            }

            // The server has caught up — it is authoritative again.
            pending[fetched.id] = nil
            return fetched
        }
    }
}
