//
//  AppStateService.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation
import AppKit

extension Notification.Name {
    /// Posted when the "Allow read-only repository access" setting is toggled.
    static let allowReadOnlyRepoAccessChanged = Notification.Name("allowReadOnlyRepoAccessChanged")
}

struct AppState: Codable {
    var sidebarWidth: Double?
    var filterState: FilterState?

    struct FilterState: Codable {
        var stateFilter: String // IssueStateFilter rawValue
        var visibilityFilter: String // VisibilityFilter rawValue
        var involvementFilter: String // InvolvementFilter rawValue
        var selectedRepositories: [String] // Convert Set to Array for Codable
        var selectedLabels: [String]? // Convert Set to Array for Codable
        var sortOption: String // SortOption id
    }
}

class AppStateService {
    static let syncEnabledKey = "syncEnabled"
    static let syncIntervalSecondsKey = "syncIntervalSeconds"
    static let allowReadOnlyRepoAccessKey = "allowReadOnlyRepoAccess"
    static let showIssueActivityKey = "showIssueActivity"

    private let defaults = UserDefaults.standard
    private let appStateKey = "appState"

    /// Saves the current app state
    func saveState(_ state: AppState) {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(state) {
            defaults.set(encoded, forKey: appStateKey)
        }
    }

    /// Loads the saved app state
    func loadState() -> AppState? {
        guard let data = defaults.data(forKey: appStateKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        return try? decoder.decode(AppState.self, from: data)
    }

    /// Saves sidebar width
    func saveSidebarWidth(_ width: Double) {
        var state = loadState() ?? AppState()
        state.sidebarWidth = width
        saveState(state)
    }

    /// Gets saved sidebar width
    func getSidebarWidth() -> Double? {
        return loadState()?.sidebarWidth
    }

    /// Saves filter state
    func saveFilterState(_ filterOptions: FilterOptions) {
        var state = loadState() ?? AppState()
        state.filterState = AppState.FilterState(
            stateFilter: filterOptions.stateFilter.rawValue,
            visibilityFilter: filterOptions.visibilityFilter.rawValue,
            involvementFilter: filterOptions.involvementFilter.rawValue,
            selectedRepositories: Array(filterOptions.selectedRepositories),
            selectedLabels: Array(filterOptions.selectedLabels),
            sortOption: filterOptions.sortOption.id
        )
        saveState(state)
    }

    static var isSyncEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: syncEnabledKey) == nil { return true }
        return defaults.bool(forKey: syncEnabledKey)
    }

    static var syncIntervalSeconds: Int {
        let defaults = UserDefaults.standard
        let value = defaults.integer(forKey: syncIntervalSecondsKey)
        return value > 0 ? value : 30
    }

    /// Whether issues from read-only (archived or no-write-access) repositories are included.
    /// Defaults to `false`, so read-only repos are hidden until the user opts in.
    static var allowReadOnlyRepoAccess: Bool {
        UserDefaults.standard.bool(forKey: allowReadOnlyRepoAccessKey)
    }

    /// Whether the issue detail panel lists GitHub's activity log alongside the comments.
    /// Defaults to `true`.
    static var showIssueActivity: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: showIssueActivityKey) == nil { return true }
        return defaults.bool(forKey: showIssueActivityKey)
    }

    /// Loads filter state and converts back to FilterOptions
    func loadFilterState() -> FilterOptions? {
        guard let state = loadState(),
              let filterState = state.filterState else {
            return nil
        }

        // Convert saved values back to enums
        guard let stateFilter = IssueStateFilter(rawValue: filterState.stateFilter),
              let visibilityFilter = VisibilityFilter(rawValue: filterState.visibilityFilter),
              let involvementFilter = InvolvementFilter(rawValue: filterState.involvementFilter) else {
            return nil
        }

        // Convert sort option id back to enum
        let sortOption: SortOption
        switch filterState.sortOption {
        case "created-asc": sortOption = .createdAsc
        case "created-desc": sortOption = .createdDesc
        case "updated-asc": sortOption = .updatedAsc
        case "updated-desc": sortOption = .updatedDesc
        case "number-asc": sortOption = .numberAsc
        case "number-desc": sortOption = .numberDesc
        default: sortOption = .updatedDesc // Default fallback
        }

        return FilterOptions(
            stateFilter: stateFilter,
            visibilityFilter: visibilityFilter,
            involvementFilter: involvementFilter,
            selectedRepositories: Set(filterState.selectedRepositories),
            selectedLabels: Set(filterState.selectedLabels ?? []),
            sortOption: sortOption,
            searchText: "" // Don't persist search text
        )
    }
}
