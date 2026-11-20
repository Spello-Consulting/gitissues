//
//  BatchLabelSelection.swift
//  GitIssues
//
//  Created by Claude Code
//
//  Issue #120: apply labels when multiple issues are selected.
//

import Foundation

/// How many of the selected issues carry a label.
enum LabelCheckState: Equatable {
    case none
    case mixed
    case all
}

/// What the user has asked to do with a label. A label with no intent is left untouched.
enum LabelIntent: Equatable {
    case add
    case remove
}

/// A label offered by the dialog: one entry per case-insensitive name across all the selected
/// issues' repositories.
struct UnionLabel: Identifiable, Equatable {
    /// Lower-cased name; the identity used to match labels across repositories.
    let key: String
    /// Display name, colour and the repositories that already have the label.
    let name: String
    let color: String
    let repositoryIDs: Set<String>

    var id: String { key }
}

/// The label changes planned for one issue. Labels are identified by lower-cased name.
struct IssueLabelChange: Equatable {
    let issue: Issue
    let add: [String]
    let remove: [String]
}

/// A label that has to be created in a repository before it can be added there.
struct RepoLabelCreation: Hashable {
    let repository: Repository
    let name: String
    let color: String
}

/// Pure helpers for the "Labels…" dialog when it works on one or more issues, possibly spanning
/// several repositories. Label IDs are per-repository, so labels are matched across repositories
/// by lower-cased name (the same rule copy/move uses).
///
/// Kanban-prefixed labels are hidden from label editing (see `Kanban.visibleLabels`), so they are
/// never offered, never removed and always preserved.
enum BatchLabelSelection {
    /// Lower-cased key identifying a label across repositories.
    static func key(_ name: String) -> String {
        name.lowercased()
    }

    /// The editable labels across all the repositories, de-duplicated by name and sorted by name.
    /// The colour comes from the first repository (in the order given) that has the label.
    static func unionLabels(_ perRepo: [(repositoryID: String, labels: [Label])]) -> [UnionLabel] {
        var order: [String] = []
        var names: [String: String] = [:]
        var colors: [String: String] = [:]
        var repos: [String: Set<String>] = [:]
        for (repositoryID, labels) in perRepo {
            for label in Kanban.visibleLabels(labels) {
                let k = key(label.name)
                if names[k] == nil {
                    order.append(k)
                    names[k] = label.name
                    colors[k] = label.color
                }
                repos[k, default: []].insert(repositoryID)
            }
        }
        return order
            .map { UnionLabel(key: $0, name: names[$0] ?? $0, color: colors[$0] ?? "", repositoryIDs: repos[$0] ?? []) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// How many of `issues` currently carry the label.
    static func state(ofLabelKey labelKey: String, in issues: [Issue]) -> LabelCheckState {
        let count = issues.filter { hasLabel(labelKey, $0) }.count
        if count == 0 { return .none }
        return count == issues.count ? .all : .mixed
    }

    /// The intent after the user clicks a label. Cycles: none → add → none; all → remove → all;
    /// mixed → add → remove → mixed.
    static func nextIntent(current: LabelIntent?, initial: LabelCheckState) -> LabelIntent? {
        switch (initial, current) {
        case (.none, nil): return .add
        case (.none, _): return nil
        case (.all, nil): return .remove
        case (.all, _): return nil
        case (.mixed, nil): return .add
        case (.mixed, .add?): return .remove
        case (.mixed, .remove?): return nil
        }
    }

    /// What the checkbox shows once the user's `intent` is applied to `initial`.
    static func displayState(initial: LabelCheckState, intent: LabelIntent?) -> LabelCheckState {
        switch intent {
        case .add?: return .all
        case .remove?: return .none
        case nil: return initial
        }
    }

    /// Per-issue changes needed to carry out `intents` (keyed by label key). Adding skips issues
    /// that already have the label, removing skips issues that lack it, and issues needing no
    /// change are omitted.
    static func plan(issues: [Issue], intents: [String: LabelIntent]) -> [IssueLabelChange] {
        let adds = intents.filter { $0.value == .add }.keys.sorted()
        let removes = intents.filter { $0.value == .remove }.keys.sorted()
        return issues.compactMap { issue in
            let present = Set(Kanban.visibleLabels(issue.labels).map { key($0.name) })
            let add = adds.filter { !present.contains($0) }
            let remove = removes.filter { present.contains($0) }
            guard !add.isEmpty || !remove.isEmpty else { return nil }
            return IssueLabelChange(issue: issue, add: add, remove: remove)
        }
    }

    /// Labels that must be created before `plan` can run: one per (repository, label) where an
    /// issue needs a label its repository doesn't have yet. `repoLabels` is keyed by repository ID.
    static func missingLabels(
        plan: [IssueLabelChange],
        repoLabels: [String: [Label]],
        union: [UnionLabel]
    ) -> [RepoLabelCreation] {
        let unionByKey = Dictionary(union.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [RepoLabelCreation] = []
        for change in plan {
            let repository = change.issue.repository
            let existing = Set((repoLabels[repository.id] ?? []).map { key($0.name) })
            for labelKey in change.add where !existing.contains(labelKey) {
                guard seen.insert("\(repository.id)\u{0}\(labelKey)").inserted else { continue }
                let label = unionByKey[labelKey]
                result.append(RepoLabelCreation(
                    repository: repository,
                    name: label?.name ?? labelKey,
                    color: label?.color ?? ""
                ))
            }
        }
        return result
    }

    /// Resolves one issue's planned change into GitHub label IDs. Additions use the repository's
    /// labels in `repoLabels`; removals use the IDs already on the issue. Additions the repository
    /// still lacks (e.g. creation failed) are dropped.
    static func resolve(
        _ change: IssueLabelChange,
        repoLabels: [String: [Label]]
    ) -> (add: [Label], removeIDs: [String]) {
        let available = Dictionary(
            (repoLabels[change.issue.repository.id] ?? []).map { (key($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let add = change.add.compactMap { available[$0] }
        let removeKeys = Set(change.remove)
        let removeIDs = Kanban.visibleLabels(change.issue.labels)
            .filter { removeKeys.contains(key($0.name)) }
            .map(\.id)
        return (add, removeIDs)
    }

    /// The issue's labels after the change is applied (existing order, removals dropped, additions
    /// appended). Kanban labels are untouched.
    static func resultingLabels(current: [Label], add: [Label], removeIDs: [String]) -> [Label] {
        let remove = Set(removeIDs)
        let kept = current.filter { !remove.contains($0.id) }
        let existing = Set(kept.map(\.id))
        return kept + add.filter { !existing.contains($0.id) }
    }

    private static func hasLabel(_ labelKey: String, _ issue: Issue) -> Bool {
        Kanban.visibleLabels(issue.labels).contains { key($0.name) == labelKey }
    }
}
