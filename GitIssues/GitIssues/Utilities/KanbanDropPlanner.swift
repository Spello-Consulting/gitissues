//
//  KanbanDropPlanner.swift
//  GitIssues
//
//  Issue #119 — pure calculation of the order keys to write when cards are dropped on a Kanban
//  column, including re-keying neighbours so the dropped card lands exactly where it was dropped.
//

import Foundation

/// The keys to write for one drop.
struct KanbanDropPlan: Equatable {
    /// One key per dropped issue, in drop order.
    let keys: [String]
    /// Neighbours that must also be re-keyed so the displayed order is preserved.
    let rekeys: [Rekey]

    struct Rekey: Equatable {
        let issueID: String
        let key: String
    }
}

/// Works out order keys for a drop into a column displayed as *keyed issues in key order (ties in
/// the selected sort order), then unkeyed issues* — the "Kanban Dragged" ordering of
/// `Kanban.columns`.
///
/// Dropping next to a neighbour with no key, or between two neighbours that share a key, cannot be
/// expressed with a single new key, because the new key would sort to the wrong side of one of
/// them. In those cases the affected neighbours (the tie group, or the unkeyed run above the drop
/// point) are re-keyed too, in their current displayed order, so nothing visibly moves except the
/// dropped cards.
enum KanbanDropPlanner {
    /// - Parameters:
    ///   - column: The column as displayed, **excluding** the issues being moved.
    ///   - index: Where the dropped cards go, as an index into `column` (`column.count` appends).
    ///   - count: How many issues are being dropped.
    static func plan(column: [Issue], index: Int, count: Int) -> KanbanDropPlan {
        precondition(count > 0, "A drop moves at least one issue")
        let index = min(max(index, 0), column.count)
        let above: Issue? = index > 0 ? column[index - 1] : nil
        let below: Issue? = index < column.count ? column[index] : nil

        // Top of the column, or empty: the dropped cards precede everything keyed.
        guard let above else {
            let upper = below?.kanbanOrderKey
            return KanbanDropPlan(keys: FractionalIndex.keysBetween(nil, upper, count: count), rekeys: [])
        }

        // Dropped beneath an unkeyed card: the unkeyed run above the drop point has to be keyed
        // (after every keyed issue) so the dropped cards can sit below it.
        guard let aboveKey = above.kanbanOrderKey else {
            let runStart = column.firstIndex { $0.kanbanOrderKey == nil } ?? index
            let run = Array(column[runStart..<index])
            let lastKeyed = runStart > 0 ? column[runStart - 1].kanbanOrderKey : nil
            let keys = FractionalIndex.keysBetween(lastKeyed, nil, count: run.count + count)
            return KanbanDropPlan(
                keys: Array(keys[run.count...]),
                rekeys: zip(run, keys).map { .init(issueID: $0.id, key: $1) }
            )
        }

        // Dropped between two cards that share a key: re-key the tie members from the drop point
        // onward so they sort after the dropped cards.
        if let belowKey = below?.kanbanOrderKey, belowKey == aboveKey {
            var group: [Issue] = []
            var next = index
            while next < column.count, column[next].kanbanOrderKey == aboveKey {
                group.append(column[next])
                next += 1
            }
            let upper = next < column.count ? column[next].kanbanOrderKey : nil
            let keys = FractionalIndex.keysBetween(aboveKey, upper, count: count + group.count)
            return KanbanDropPlan(
                keys: Array(keys[..<count]),
                rekeys: zip(group, keys[count...]).map { .init(issueID: $0.id, key: $1) }
            )
        }

        // Ordinary case: a key strictly between the neighbours' keys (the upper bound is open when
        // the card below is unkeyed or there is none).
        let belowKey = below?.kanbanOrderKey
        return KanbanDropPlan(keys: FractionalIndex.keysBetween(aboveKey, belowKey, count: count), rekeys: [])
    }
}
