//
//  Repository.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

struct Repository: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let owner: User
    let isPrivate: Bool
    /// Whether the repository is archived on GitHub (archived repos reject all issue mutations).
    let isArchived: Bool
    /// The viewer's permission on the repository (ADMIN, MAINTAIN, WRITE, TRIAGE, READ) or nil.
    let viewerPermission: String?

    var fullName: String {
        "\(owner.login)/\(name)"
    }

    /// A repository is read-only when it's archived, or the viewer lacks write access. Issue
    /// mutations (edit, close, assign, delete, kanban moves) are rejected by GitHub in this case.
    var isReadOnly: Bool {
        if isArchived { return true }
        return !["ADMIN", "MAINTAIN", "WRITE"].contains(viewerPermission ?? "")
    }

    init(
        id: String,
        name: String,
        owner: User,
        isPrivate: Bool,
        isArchived: Bool = false,
        viewerPermission: String? = nil
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.isPrivate = isPrivate
        self.isArchived = isArchived
        self.viewerPermission = viewerPermission
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case owner
        case isPrivate
        case isArchived
        case viewerPermission
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        owner = try container.decode(User.self, forKey: .owner)
        isPrivate = try container.decode(Bool.self, forKey: .isPrivate)
        // Defaulted so older cached payloads (without these fields) still decode.
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        viewerPermission = try container.decodeIfPresent(String.self, forKey: .viewerPermission)
    }
}

extension Array where Element == Repository {
    /// Sorted by repository name, case-insensitively — the same order as the Copy/Move destination
    /// picker (GitHub's `NAME` ordering). `fullName` breaks ties between same-named repos.
    func sortedByName() -> [Repository] {
        sorted {
            let byName = $0.name.localizedCaseInsensitiveCompare($1.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return $0.fullName.localizedCaseInsensitiveCompare($1.fullName) == .orderedAscending
        }
    }
}
