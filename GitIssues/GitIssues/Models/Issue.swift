//
//  Issue.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

enum IssueState: String, Codable {
    case open = "OPEN"
    case closed = "CLOSED"
}

struct Issue: Codable, Identifiable, Hashable {
    let id: String
    let number: Int
    let title: String
    let body: String?
    let state: IssueState
    let createdAt: Date
    let updatedAt: Date
    let repository: Repository
    let labels: [Label]
    let assignees: [User]
    let author: User?

    /// The Kanban board order key stored in `body` (see `KanbanOrderMarker`), or `nil`.
    ///
    /// Computed once when the issue is created rather than on every access: the board reads it
    /// several times per issue on each render (filtering, sorting, neighbour lookup), and parsing
    /// means scanning the whole body with a regular expression. Derived from `body`, so it is not
    /// encoded, and always stays consistent with it (`body` is immutable).
    let kanbanOrderKey: String?

    init(
        id: String,
        number: Int,
        title: String,
        body: String?,
        state: IssueState,
        createdAt: Date,
        updatedAt: Date,
        repository: Repository,
        labels: [Label],
        assignees: [User],
        author: User?
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.body = body
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.repository = repository
        self.labels = labels
        self.assignees = assignees
        self.author = author
        self.kanbanOrderKey = KanbanOrderMarker.parse(from: body)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            number: try container.decode(Int.self, forKey: .number),
            title: try container.decode(String.self, forKey: .title),
            body: try container.decodeIfPresent(String.self, forKey: .body),
            state: try container.decode(IssueState.self, forKey: .state),
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            repository: try container.decode(Repository.self, forKey: .repository),
            labels: try container.decode([Label].self, forKey: .labels),
            assignees: try container.decode([User].self, forKey: .assignees),
            author: try container.decodeIfPresent(User.self, forKey: .author)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(number, forKey: .number)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encode(state, forKey: .state)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(repository, forKey: .repository)
        try container.encode(labels, forKey: .labels)
        try container.encode(assignees, forKey: .assignees)
        try container.encodeIfPresent(author, forKey: .author)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case body
        case state
        case createdAt
        case updatedAt
        case repository
        case labels
        case assignees
        case author
    }

    /// The repository's full name, with a " (read-only)" suffix when the repo is archived or the
    /// viewer lacks write access — used for display in the issue list and kanban cards.
    var repositoryDisplayName: String {
        repository.isReadOnly ? "\(repository.fullName) (read-only)" : repository.fullName
    }
}
