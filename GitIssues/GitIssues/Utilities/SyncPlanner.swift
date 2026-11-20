//
//  SyncPlanner.swift
//  GitIssues
//
//  Issue #109 — decides between a full and an incremental issue sync.
//

import Foundation

/// How to bring the in-memory issue list up to date.
enum SyncMode: Equatable {
    /// Download every issue (open and closed) and replace the list. Detects deletions, transfers and
    /// issues that stopped matching the search.
    case full
    /// Download only issues updated at or after `since` and merge them in. One small request
    /// instead of ~6, but it cannot notice an issue that disappeared.
    case incremental(since: Date)
}

enum SyncPlanner {
    /// Longest an issue list may go without a full sync. Bounds how long a deleted/transferred
    /// issue can linger, since incremental syncs only ever see changes.
    static let fullReconcileInterval: TimeInterval = 10 * 60

    /// How far before the last sync an incremental query reaches back. GitHub's search index lags
    /// behind writes by seconds (occasionally longer), so an issue updated just before the last
    /// sync may not have been indexed when that sync ran. Re-fetching a few minutes of overlap is
    /// cheap and closes that gap.
    static let incrementalOverlap: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - lastFullSyncAt: When the last complete fetch started (`nil` if none, e.g. no cache).
    ///   - lastSyncAt: When the most recent fetch of either kind started.
    ///   - now: The current time.
    static func mode(lastFullSyncAt: Date?, lastSyncAt: Date?, now: Date = Date()) -> SyncMode {
        guard let lastFullSyncAt, let lastSyncAt else { return .full }

        // A clock that moved backwards, or a sync time before the full sync, can't be trusted.
        let sinceFull = now.timeIntervalSince(lastFullSyncAt)
        guard sinceFull >= 0, sinceFull < fullReconcileInterval, lastSyncAt >= lastFullSyncAt else {
            return .full
        }
        return .incremental(since: lastSyncAt.addingTimeInterval(-incrementalOverlap))
    }
}
