//
//  KanbanMovePlanner.swift
//  GitIssues
//
//  Issue #109 — pure label-set calculation for Kanban moves and closes.
//

import Foundation

/// Works out an issue's new label set for a Kanban move, so the whole change can be written with a
/// single `updateIssue(labelIds:)` mutation instead of separate remove / add / update calls (each
/// GitHub mutation costs ~1–1.5 s).
enum KanbanMovePlanner {
    /// The list query returns at most this many labels per issue. An issue showing this many may
    /// have more that were cut off, so its cached label list must not be used to *replace* the set.
    static let possiblyTruncatedLabelCount = 10

    /// The label ids the issue should have after the move: its current labels, minus any managed
    /// Kanban label (matched case-insensitively by name), plus `target` (when given).
    ///
    /// - Returns: The new ids in a stable order, or `nil` when the set is unchanged (e.g. reordering
    ///   within a column) so the caller can leave labels out of the mutation entirely.
    static func labelUpdate(
        currentLabels: [Label],
        managedLabelNames: Set<String>,
        adding target: Label?
    ) -> [String]? {
        var ids = currentLabels
            .filter { !managedLabelNames.contains($0.name.lowercased()) }
            .map(\.id)
        if let target, !ids.contains(target.id) {
            ids.append(target.id)
        }
        return Set(ids) == Set(currentLabels.map(\.id)) ? nil : ids
    }
}
