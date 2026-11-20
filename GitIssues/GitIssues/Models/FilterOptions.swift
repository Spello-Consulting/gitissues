//
//  FilterOptions.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

enum IssueStateFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case open = "Open"
    case closed = "Closed"

    var id: String { rawValue }

    var issueStates: [IssueState]? {
        switch self {
        case .all: return nil
        case .open: return [.open]
        case .closed: return [.closed]
        }
    }
}

enum VisibilityFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case publicRepos = "Public"
    case privateRepos = "Private"

    var id: String { rawValue }
}

enum InvolvementFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case createdByMe = "Created by me"
    case assignedToMe = "Assigned to me"
    case other = "Other"

    var id: String { rawValue }

    var displayName: String { rawValue }
}

enum SortOption: Identifiable {
    case createdAsc
    case createdDesc
    case updatedAsc
    case updatedDesc
    case numberAsc
    case numberDesc

    var id: String {
        switch self {
        case .createdAsc: return "created-asc"
        case .createdDesc: return "created-desc"
        case .updatedAsc: return "updated-asc"
        case .updatedDesc: return "updated-desc"
        case .numberAsc: return "number-asc"
        case .numberDesc: return "number-desc"
        }
    }

    var displayName: String {
        switch self {
        case .createdAsc: return "Created (Oldest)"
        case .createdDesc: return "Created (Newest)"
        case .updatedAsc: return "Updated (Oldest)"
        case .updatedDesc: return "Updated (Newest)"
        case .numberAsc: return "Issue # (Low to High)"
        case .numberDesc: return "Issue # (High to Low)"
        }
    }

    func sort(_ issues: [Issue]) -> [Issue] {
        switch self {
        case .createdAsc:
            return issues.sorted { $0.createdAt < $1.createdAt }
        case .createdDesc:
            return issues.sorted { $0.createdAt > $1.createdAt }
        case .updatedAsc:
            return issues.sorted { $0.updatedAt < $1.updatedAt }
        case .updatedDesc:
            return issues.sorted { $0.updatedAt > $1.updatedAt }
        case .numberAsc:
            return issues.sorted { $0.number < $1.number }
        case .numberDesc:
            return issues.sorted { $0.number > $1.number }
        }
    }
}

struct FilterOptions {
    var stateFilter: IssueStateFilter = .open
    var visibilityFilter: VisibilityFilter = .all
    var involvementFilter: InvolvementFilter = .all
    var selectedRepositories: Set<String> = []
    var selectedLabels: Set<String> = []
    var sortOption: SortOption = .updatedDesc
    /// Kanban board only: when `true`, cards are ordered by their dragged order key first and then by
    /// `sortOption`; when `false` the keys are ignored and only `sortOption` applies. Not used by the
    /// issue list, and not part of `matches(issue:viewerLogin:)`.
    var kanbanDragged: Bool = true
    var searchText: String = ""
    /// Whether issues from read-only (archived / no-write-access) repos are shown.
    /// Not persisted in filter state — mirrored from `AppStateService.allowReadOnlyRepoAccess`.
    var allowReadOnly: Bool = AppStateService.allowReadOnlyRepoAccess

    func matches(issue: Issue, viewerLogin: String?) -> Bool {
        // Hide read-only repos (archived or no write access) unless the user opted in.
        if !allowReadOnly && issue.repository.isReadOnly {
            return false
        }

        // Check state filter
        switch stateFilter {
        case .all:
            break
        case .open:
            if issue.state != .open { return false }
        case .closed:
            if issue.state != .closed { return false }
        }

        // Check visibility filter
        switch visibilityFilter {
        case .all:
            break
        case .publicRepos:
            if issue.repository.isPrivate { return false }
        case .privateRepos:
            if !issue.repository.isPrivate { return false }
        }

        // Check involvement filter
        if let viewerLogin = viewerLogin {
            switch involvementFilter {
            case .all:
                break
            case .createdByMe:
                if issue.author?.login != viewerLogin {
                    return false
                }
            case .assignedToMe:
                if !issue.assignees.contains(where: { $0.login == viewerLogin }) {
                    return false
                }
            case .other:
                // Neither created by me nor assigned to me
                let isCreatedByMe = issue.author?.login == viewerLogin
                let isAssignedToMe = issue.assignees.contains(where: { $0.login == viewerLogin })
                if isCreatedByMe || isAssignedToMe {
                    return false
                }
            }
        }

        // Check repository filter
        if !selectedRepositories.isEmpty {
            if !selectedRepositories.contains(issue.repository.id) {
                return false
            }
        }

        // Check label filter (OR logic, case-insensitive by name)
        if !selectedLabels.isEmpty {
            let issueLabels = Set(issue.labels.map { $0.name.lowercased() })
            if issueLabels.isDisjoint(with: selectedLabels) {
                return false
            }
        }

        // Check search text
        if !searchText.isEmpty {
            let searchLower = searchText.lowercased()
            let titleMatch = issue.title.lowercased().contains(searchLower)
            let bodyMatch = issue.body?.lowercased().contains(searchLower) ?? false
            let repoMatch = issue.repository.fullName.lowercased().contains(searchLower)

            if !titleMatch && !bodyMatch && !repoMatch {
                return false
            }
        }

        return true
    }

    func matchesExcludingLabels(issue: Issue, viewerLogin: String?) -> Bool {
        var copy = self
        copy.selectedLabels = []
        return copy.matches(issue: issue, viewerLogin: viewerLogin)
    }
}
