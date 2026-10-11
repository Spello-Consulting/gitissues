//
//  KanbanSettingsService.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import Combine

/// Stores and validates the user's Kanban board configuration (the ordered list of states).
///
/// Persists to `UserDefaults` as a JSON blob, mirroring `AppearanceService.shared`.
@MainActor
final class KanbanSettingsService: ObservableObject {
    static let shared = KanbanSettingsService()

    /// Ordered list of states. The first is the open default; exactly one is closed.
    @Published var states: [KanbanState] {
        didSet { save() }
    }

    private let userDefaultsKey = "kanbanStates"

    /// Minimum / maximum number of states the UI allows.
    static let minStates = 2
    static let maxStates = 6

    static let defaultStates: [KanbanState] = [
        KanbanState(name: "Backlog", isClosed: false),
        KanbanState(name: "Selected for Development", isClosed: false),
        KanbanState(name: "In Progress", isClosed: false),
        KanbanState(name: "Done", isClosed: true)
    ]

    private init() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let decoded = try? JSONDecoder().decode([KanbanState].self, from: data),
           decoded.count >= Self.minStates {
            self.states = decoded
        } else {
            self.states = Self.defaultStates
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }

    // MARK: - Derived

    /// The default state for open issues with no Kanban label (the first state).
    var defaultState: KanbanState { states.first ?? Self.defaultStates[0] }

    /// The single closed state — where closed issues with no Kanban label live.
    var closedState: KanbanState {
        states.first(where: { $0.isClosed }) ?? states.last ?? Self.defaultStates[3]
    }

    /// Lowercased names of the labels this instance manages (one per configured state).
    var managedLabelNames: Set<String> {
        Set(states.map { Kanban.labelName(for: $0).lowercased() })
    }

    /// The palette color (6-char hex, no `#`) to use when auto-creating this state's label.
    func color(for state: KanbanState) -> String {
        let index = states.firstIndex(where: { $0.id == state.id }) ?? 0
        return Kanban.color(forIndex: index)
    }

    // MARK: - Placement

    /// Determines which column an issue belongs to. See `Kanban.state(for:in:closedState:defaultState:)`
    /// for the placement rules.
    func state(for issue: Issue) -> KanbanState {
        Kanban.state(for: issue, in: states, closedState: closedState, defaultState: defaultState)
    }
}
