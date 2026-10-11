//
//  Label.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

struct Label: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let color: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case color
    }
}

/// Pure helpers for the "Labels…" dialog: working out what to add/remove on an issue.
///
/// Kanban-prefixed labels are hidden from label editing (see `Kanban.visibleLabels`), so they are
/// never offered, never removed by "unselecting", and always preserved on the issue.
enum LabelSelection {
    /// Label IDs to add to / remove from an issue so that its editable (non-Kanban) labels match
    /// `selectedIds`.
    static func changes(current: [Label], selectedIds: Set<String>) -> (add: [String], remove: [String]) {
        let currentIds = Set(Kanban.visibleLabels(current).map(\.id))
        let add = selectedIds.subtracting(currentIds).sorted()
        let remove = currentIds.subtracting(selectedIds).sorted()
        return (add, remove)
    }

    /// The issue's labels after applying `selected`: its existing Kanban labels plus the selection.
    static func resulting(current: [Label], selected: [Label]) -> [Label] {
        let kanban = current.filter { Kanban.isKanbanLabel($0.name) }
        return kanban + selected.filter { !Kanban.isKanbanLabel($0.name) }
    }
}
