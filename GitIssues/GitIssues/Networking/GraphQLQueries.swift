//
//  GraphQLQueries.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

struct GraphQLQueries {
    /// Query to fetch the authenticated user's login
    static let viewerQuery = """
    query Viewer {
      viewer {
        login
      }
    }
    """

    /// Query to fetch all issues involving the authenticated user using search
    static let allIssuesQuery = """
    query AllIssues($query: String!, $cursor: String, $first: Int = 50) {
      search(query: $query, type: ISSUE, first: $first, after: $cursor) {
        pageInfo {
          hasNextPage
          endCursor
        }
        nodes {
          ... on Issue {
            id
            number
            title
            body
            state
            createdAt
            updatedAt
            repository {
              id
              name
              owner {
                id
                login
                avatarUrl
              }
              isPrivate
              isArchived
              viewerPermission
            }
            labels(first: 10) {
              nodes {
                id
                name
                color
              }
            }
            assignees(first: 10) {
              nodes {
                ... on User {
                  id
                  login
                  avatarUrl
                }
              }
            }
            author {
              ... on User {
                id
                login
                avatarUrl
              }
            }
          }
        }
      }
    }
    """

    /// Query to fetch a specific issue with its comments
    static let issueDetailQuery = """
    query IssueDetail($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          id
          number
          title
          body
          state
          createdAt
          updatedAt
          repository {
            id
            name
            owner {
              id
              login
              avatarUrl
            }
            isPrivate
            isArchived
            viewerPermission
          }
          labels(first: 20) {
            nodes {
              id
              name
              color
            }
          }
          assignees(first: 20) {
            nodes {
              ... on User {
                id
                login
                avatarUrl
              }
            }
          }
          author {
            ... on User {
              id
              login
              avatarUrl
            }
          }
          comments(first: 100) {
            nodes {
              id
              body
              createdAt
              updatedAt
              author {
                ... on User {
                  id
                  login
                  avatarUrl
                }
              }
            }
          }
        }
      }
    }
    """

    /// Query to fetch an issue's activity log (labels, close/reopen, assignment, renames, ...).
    /// Comments are excluded — they come from `issueDetailQuery`. Fetched separately so a problem
    /// with the log can never prevent the issue itself from loading.
    static let issueActivityQuery = """
    query IssueActivity($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        issue(number: $number) {
          timelineItems(first: 100, itemTypes: [LABELED_EVENT, UNLABELED_EVENT, CLOSED_EVENT, REOPENED_EVENT, ASSIGNED_EVENT, UNASSIGNED_EVENT, RENAMED_TITLE_EVENT, MILESTONED_EVENT, DEMILESTONED_EVENT, LOCKED_EVENT, UNLOCKED_EVENT, CROSS_REFERENCED_EVENT, TRANSFERRED_EVENT]) {
            nodes {
              __typename
              ... on LabeledEvent { id createdAt actor { login avatarUrl } label { id name color } }
              ... on UnlabeledEvent { id createdAt actor { login avatarUrl } label { id name color } }
              ... on ClosedEvent { id createdAt actor { login avatarUrl } stateReason }
              ... on ReopenedEvent { id createdAt actor { login avatarUrl } }
              ... on AssignedEvent { id createdAt actor { login avatarUrl } assignee { ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } } }
              ... on UnassignedEvent { id createdAt actor { login avatarUrl } assignee { ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Organization { login } } }
              ... on RenamedTitleEvent { id createdAt actor { login avatarUrl } previousTitle currentTitle }
              ... on MilestonedEvent { id createdAt actor { login avatarUrl } milestoneTitle }
              ... on DemilestonedEvent { id createdAt actor { login avatarUrl } milestoneTitle }
              ... on LockedEvent { id createdAt actor { login avatarUrl } lockReason }
              ... on UnlockedEvent { id createdAt actor { login avatarUrl } }
              ... on CrossReferencedEvent { id createdAt actor { login avatarUrl } source { __typename ... on Issue { number title repository { nameWithOwner } } ... on PullRequest { number title repository { nameWithOwner } } } }
              ... on TransferredEvent { id createdAt actor { login avatarUrl } fromRepository { nameWithOwner } }
            }
          }
        }
      }
    }
    """

    /// Query to fetch all repositories the user can open issues in, including those
    /// owned by organisations they belong to.
    static let repositoriesQuery = """
    query Repositories($cursor: String, $first: Int = 100) {
      viewer {
        repositories(first: $first, after: $cursor, affiliations: [OWNER, COLLABORATOR, ORGANIZATION_MEMBER], ownerAffiliations: [OWNER, ORGANIZATION_MEMBER], orderBy: {field: NAME, direction: ASC}) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            name
            owner {
              login
            }
            isPrivate
            hasIssuesEnabled
            isArchived
            viewerPermission
          }
        }
      }
    }
    """

    /// Query to fetch labels for a repository
    static let repositoryLabelsQuery = """
    query RepositoryLabels($owner: String!, $repo: String!, $cursor: String, $first: Int = 100) {
      repository(owner: $owner, name: $repo) {
        labels(first: $first, after: $cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            name
            color
          }
        }
      }
    }
    """

    /// Mutation to create a new issue
    static let createIssueMutation = """
    mutation CreateIssue($repositoryId: ID!, $title: String!, $body: String, $labelIds: [ID!]) {
      createIssue(input: {repositoryId: $repositoryId, title: $title, body: $body, labelIds: $labelIds}) {
        issue {
          id
          number
          title
          body
          state
          createdAt
          updatedAt
          repository {
            id
            name
            owner {
              id
              login
              avatarUrl
            }
            isPrivate
            isArchived
            viewerPermission
          }
          labels(first: 10) {
            nodes {
              id
              name
              color
            }
          }
          assignees(first: 10) {
            nodes {
              ... on User {
                id
                login
                avatarUrl
              }
            }
          }
          author {
            ... on User {
              id
              login
              avatarUrl
            }
          }
        }
      }
    }
    """

    /// Mutation to update an existing issue
    static let updateIssueMutation = """
    mutation UpdateIssue($id: ID!, $title: String, $body: String, $state: IssueState) {
      updateIssue(input: {id: $id, title: $title, body: $body, state: $state}) {
        issue {
          id
          number
          title
          body
          state
          createdAt
          updatedAt
          repository {
            id
            name
            owner {
              id
              login
              avatarUrl
            }
            isPrivate
            isArchived
            viewerPermission
          }
          labels(first: 10) {
            nodes {
              id
              name
              color
            }
          }
          assignees(first: 10) {
            nodes {
              ... on User {
                id
                login
                avatarUrl
              }
            }
          }
          author {
            ... on User {
              id
              login
              avatarUrl
            }
          }
        }
      }
    }
    """

    /// Mutation to add a comment to an issue
    static let addCommentMutation = """
    mutation AddComment($subjectId: ID!, $body: String!) {
      addComment(input: {subjectId: $subjectId, body: $body}) {
        commentEdge {
          node {
            id
            body
            createdAt
            updatedAt
            author {
              ... on User {
                id
                login
                avatarUrl
              }
            }
          }
        }
      }
    }
    """

    /// Mutation to update a comment
    static let updateCommentMutation = """
    mutation UpdateComment($id: ID!, $body: String!) {
      updateIssueComment(input: {id: $id, body: $body}) {
        issueComment {
          id
          body
          createdAt
          updatedAt
          author {
            ... on User {
              id
              login
              avatarUrl
            }
          }
        }
      }
    }
    """

    /// Mutation to delete a comment
    static let deleteCommentMutation = """
    mutation DeleteComment($id: ID!) {
      deleteIssueComment(input: {id: $id}) {
        clientMutationId
      }
    }
    """

    /// Mutation to delete an issue
    static let deleteIssueMutation = """
    mutation DeleteIssue($id: ID!) {
      deleteIssue(input: {issueId: $id}) {
        clientMutationId
      }
    }
    """

    /// Mutation to add labels to an issue
    static let createLabelMutation = """
    mutation CreateLabel($repositoryId: ID!, $name: String!, $color: String!) {
      createLabel(input: {repositoryId: $repositoryId, name: $name, color: $color}) {
        label {
          id
          name
          color
        }
      }
    }
    """

    static let addLabelsToIssueMutation = """
    mutation AddLabels($issueId: ID!, $labelIds: [ID!]!) {
      addLabelsToLabelable(input: {labelableId: $issueId, labelIds: $labelIds}) {
        clientMutationId
      }
    }
    """

    /// Mutation to remove labels from an issue
    static let removeLabelsFromIssueMutation = """
    mutation RemoveLabels($issueId: ID!, $labelIds: [ID!]!) {
      removeLabelsFromLabelable(input: {labelableId: $issueId, labelIds: $labelIds}) {
        clientMutationId
      }
    }
    """

    /// Query to fetch collaborators for a repository
    static let repositoryCollaboratorsQuery = """
    query RepositoryCollaborators($owner: String!, $repo: String!, $cursor: String, $first: Int = 100) {
      repository(owner: $owner, name: $repo) {
        collaborators(first: $first, after: $cursor) {
          pageInfo {
            hasNextPage
            endCursor
          }
          nodes {
            id
            login
            avatarUrl
          }
        }
      }
    }
    """

    /// Mutation to add assignees to an issue
    static let addAssigneesToIssueMutation = """
    mutation AddAssignees($assignableId: ID!, $assigneeIds: [ID!]!) {
      addAssigneesToAssignable(input: {assignableId: $assignableId, assigneeIds: $assigneeIds}) {
        clientMutationId
      }
    }
    """

    /// Mutation to remove assignees from an issue
    static let removeAssigneesFromIssueMutation = """
    mutation RemoveAssignees($assignableId: ID!, $assigneeIds: [ID!]!) {
      removeAssigneesFromAssignable(input: {assignableId: $assignableId, assigneeIds: $assigneeIds}) {
        clientMutationId
      }
    }
    """
}

// Response structures for GraphQL queries
struct AllIssuesResponse: Codable {
    let search: SearchConnection

    struct SearchConnection: Codable {
        let pageInfo: PageInfo
        let nodes: [IssueNode?]

        enum CodingKeys: String, CodingKey {
            case pageInfo
            case nodes
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            pageInfo = try container.decode(PageInfo.self, forKey: .pageInfo)

            // Decode nodes array, gracefully handling empty objects from non-Issue types (like PRs)
            var nodesContainer = try container.nestedUnkeyedContainer(forKey: .nodes)
            var decodedNodes: [IssueNode?] = []

            while !nodesContainer.isAtEnd {
                // Try to decode each node, if it fails (empty object), append nil
                if let node = try? nodesContainer.decode(IssueNode.self) {
                    decodedNodes.append(node)
                } else {
                    // Skip the empty/invalid node
                    _ = try? nodesContainer.decode(AnyCodable.self)
                    decodedNodes.append(nil)
                }
            }

            nodes = decodedNodes
        }
    }

    struct PageInfo: Codable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct IssueNode: Codable {
        let id: String
        let number: Int
        let title: String
        let body: String?
        let state: IssueState
        let createdAt: Date
        let updatedAt: Date
        let repository: RepositoryNode
        let labels: LabelsConnection
        let assignees: AssigneesConnection
        let author: AuthorNode?

        func toIssue() -> Issue {
            Issue(
                id: id,
                number: number,
                title: title,
                body: body,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                repository: repository.toRepository(),
                labels: labels.nodes.map { $0.toLabel() },
                assignees: assignees.nodes.map { $0.toUser() },
                author: author?.toUser()
            )
        }
    }

    struct RepositoryNode: Codable {
        let id: String
        let name: String
        let owner: OwnerNode
        let isPrivate: Bool
        let isArchived: Bool?
        let viewerPermission: String?

        func toRepository() -> Repository {
            Repository(
                id: id,
                name: name,
                owner: owner.toUser(),
                isPrivate: isPrivate,
                isArchived: isArchived ?? false,
                viewerPermission: viewerPermission
            )
        }
    }

    struct OwnerNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct LabelsConnection: Codable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            Label(id: id, name: name, color: color)
        }
    }

    struct AssigneesConnection: Codable {
        let nodes: [AssigneeNode]
    }

    struct AssigneeNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for the issue activity (timeline) query
struct IssueActivityResponse: Codable {
    let repository: RepositoryNode

    struct RepositoryNode: Codable {
        let issue: IssueNode
    }

    struct IssueNode: Codable {
        let timelineItems: TimelineItems
    }

    struct TimelineItems: Codable {
        let nodes: [TimelineNode]

        enum CodingKeys: String, CodingKey {
            case nodes
        }

        /// Decodes each node independently, skipping `null`s and any node that fails to decode,
        /// so one odd event can't blank the whole activity log.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .nodes)
            var decoded: [TimelineNode] = []
            while !list.isAtEnd {
                if let node = try? list.decode(TimelineNode.self) {
                    decoded.append(node)
                } else {
                    // A failed decode doesn't advance the container; consume the element.
                    _ = try? list.decode(SkippedElement.self)
                }
            }
            nodes = decoded
        }
    }

    /// Placeholder used to step over an element that could not be decoded.
    private struct SkippedElement: Codable {
        init(from decoder: Decoder) throws {}
        func encode(to encoder: Encoder) throws {}
    }

    struct ActorNode: Codable {
        let login: String
        let avatarUrl: String?
    }

    struct LoginNode: Codable {
        let login: String?
    }

    struct NameWithOwnerNode: Codable {
        let nameWithOwner: String?
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String
    }

    struct SourceNode: Codable {
        let typename: String?
        let number: Int?
        let title: String?
        let repository: NameWithOwnerNode?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case number, title, repository
        }
    }

    /// One polymorphic timeline node. Every field except `__typename` is optional because which
    /// ones are present depends on the event type.
    struct TimelineNode: Codable {
        let typename: String
        let id: String?
        let createdAt: Date?
        let actor: ActorNode?
        let label: LabelNode?
        let stateReason: String?
        let assignee: LoginNode?
        let previousTitle: String?
        let currentTitle: String?
        let milestoneTitle: String?
        let lockReason: String?
        let source: SourceNode?
        let fromRepository: NameWithOwnerNode?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, createdAt, actor, label, stateReason, assignee, previousTitle, currentTitle
            case milestoneTitle, lockReason, source, fromRepository
        }

        /// Converts to a domain event, or nil for node types / shapes we don't display.
        func toActivity() -> IssueActivity? {
            guard let id, let createdAt else { return nil }

            let kind: IssueActivity.Kind
            switch typename {
            case "LabeledEvent":
                guard let label else { return nil }
                kind = .labeled(Label(id: label.id, name: label.name, color: label.color))
            case "UnlabeledEvent":
                guard let label else { return nil }
                kind = .unlabeled(Label(id: label.id, name: label.name, color: label.color))
            case "ClosedEvent":
                kind = .closed(reason: stateReason)
            case "ReopenedEvent":
                kind = .reopened
            case "AssignedEvent":
                kind = .assigned(login: assignee?.login)
            case "UnassignedEvent":
                kind = .unassigned(login: assignee?.login)
            case "RenamedTitleEvent":
                guard let previousTitle, let currentTitle else { return nil }
                kind = .renamed(from: previousTitle, to: currentTitle)
            case "MilestonedEvent":
                kind = .milestoned(title: milestoneTitle ?? "")
            case "DemilestonedEvent":
                kind = .demilestoned(title: milestoneTitle ?? "")
            case "LockedEvent":
                kind = .locked(reason: lockReason)
            case "UnlockedEvent":
                kind = .unlocked
            case "CrossReferencedEvent":
                guard let number = source?.number, let title = source?.title else { return nil }
                kind = .crossReferenced(
                    number: number,
                    title: title,
                    repository: source?.repository?.nameWithOwner,
                    isPullRequest: source?.typename == "PullRequest"
                )
            case "TransferredEvent":
                kind = .transferred(from: fromRepository?.nameWithOwner)
            default:
                return nil
            }

            return IssueActivity(
                id: id,
                actor: actor.map { IssueActivity.Actor(login: $0.login, avatarUrl: $0.avatarUrl) },
                createdAt: createdAt,
                kind: kind
            )
        }
    }
}

// Response structure for issue detail query
struct IssueDetailResponse: Codable {
    let repository: RepositoryDetail

    struct RepositoryDetail: Codable {
        let issue: IssueDetailNode
    }

    struct IssueDetailNode: Codable {
        let id: String
        let number: Int
        let title: String
        let body: String?
        let state: IssueState
        let createdAt: Date
        let updatedAt: Date
        let repository: RepositoryNode
        let labels: LabelsConnection
        let assignees: AssigneesConnection
        let author: AuthorNode?
        let comments: CommentsConnection

        func toIssue() -> Issue {
            Issue(
                id: id,
                number: number,
                title: title,
                body: body,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                repository: repository.toRepository(),
                labels: labels.nodes.map { $0.toLabel() },
                assignees: assignees.nodes.map { $0.toUser() },
                author: author?.toUser()
            )
        }

        func toComments() -> [Comment] {
            comments.nodes.map { $0.toComment() }
        }
    }

    struct RepositoryNode: Codable {
        let id: String
        let name: String
        let owner: OwnerNode
        let isPrivate: Bool
        let isArchived: Bool?
        let viewerPermission: String?

        func toRepository() -> Repository {
            Repository(
                id: id,
                name: name,
                owner: owner.toUser(),
                isPrivate: isPrivate,
                isArchived: isArchived ?? false,
                viewerPermission: viewerPermission
            )
        }
    }

    struct OwnerNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct LabelsConnection: Codable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            Label(id: id, name: name, color: color)
        }
    }

    struct AssigneesConnection: Codable {
        let nodes: [AssigneeNode]
    }

    struct AssigneeNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct CommentsConnection: Codable {
        let nodes: [CommentNode]
    }

    struct CommentNode: Codable {
        let id: String
        let body: String
        let createdAt: Date
        let updatedAt: Date
        let author: CommentAuthorNode?

        func toComment() -> Comment {
            Comment(
                id: id,
                body: body,
                author: author?.toUser(),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    struct CommentAuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for create issue mutation
struct CreateIssueResponse: Codable {
    let createIssue: CreateIssuePayload

    struct CreateIssuePayload: Codable {
        let issue: IssueNode
    }

    struct IssueNode: Codable {
        let id: String
        let number: Int
        let title: String
        let body: String?
        let state: IssueState
        let createdAt: Date
        let updatedAt: Date
        let repository: RepositoryNode
        let labels: LabelsConnection
        let assignees: AssigneesConnection
        let author: AuthorNode?

        func toIssue() -> Issue {
            Issue(
                id: id,
                number: number,
                title: title,
                body: body,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                repository: repository.toRepository(),
                labels: labels.nodes.map { $0.toLabel() },
                assignees: assignees.nodes.map { $0.toUser() },
                author: author?.toUser()
            )
        }
    }

    struct RepositoryNode: Codable {
        let id: String
        let name: String
        let owner: OwnerNode
        let isPrivate: Bool
        let isArchived: Bool?
        let viewerPermission: String?

        func toRepository() -> Repository {
            Repository(
                id: id,
                name: name,
                owner: owner.toUser(),
                isPrivate: isPrivate,
                isArchived: isArchived ?? false,
                viewerPermission: viewerPermission
            )
        }
    }

    struct OwnerNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct LabelsConnection: Codable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            Label(id: id, name: name, color: color)
        }
    }

    struct AssigneesConnection: Codable {
        let nodes: [AssigneeNode]
    }

    struct AssigneeNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for update issue mutation
struct UpdateIssueResponse: Codable {
    let updateIssue: UpdateIssuePayload

    struct UpdateIssuePayload: Codable {
        let issue: IssueNode
    }

    struct IssueNode: Codable {
        let id: String
        let number: Int
        let title: String
        let body: String?
        let state: IssueState
        let createdAt: Date
        let updatedAt: Date
        let repository: RepositoryNode
        let labels: LabelsConnection
        let assignees: AssigneesConnection
        let author: AuthorNode?

        func toIssue() -> Issue {
            Issue(
                id: id,
                number: number,
                title: title,
                body: body,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt,
                repository: repository.toRepository(),
                labels: labels.nodes.map { $0.toLabel() },
                assignees: assignees.nodes.map { $0.toUser() },
                author: author?.toUser()
            )
        }
    }

    struct RepositoryNode: Codable {
        let id: String
        let name: String
        let owner: OwnerNode
        let isPrivate: Bool
        let isArchived: Bool?
        let viewerPermission: String?

        func toRepository() -> Repository {
            Repository(
                id: id,
                name: name,
                owner: owner.toUser(),
                isPrivate: isPrivate,
                isArchived: isArchived ?? false,
                viewerPermission: viewerPermission
            )
        }
    }

    struct OwnerNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct LabelsConnection: Codable {
        let nodes: [LabelNode]
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            Label(id: id, name: name, color: color)
        }
    }

    struct AssigneesConnection: Codable {
        let nodes: [AssigneeNode]
    }

    struct AssigneeNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for add comment mutation
struct AddCommentResponse: Codable {
    let addComment: AddCommentPayload

    struct AddCommentPayload: Codable {
        let commentEdge: CommentEdge
    }

    struct CommentEdge: Codable {
        let node: CommentNode
    }

    struct CommentNode: Codable {
        let id: String
        let body: String
        let createdAt: Date
        let updatedAt: Date
        let author: AuthorNode?

        func toComment() -> Comment {
            Comment(
                id: id,
                body: body,
                author: author?.toUser(),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for update comment mutation
struct UpdateCommentResponse: Codable {
    let updateIssueComment: UpdateIssueCommentPayload

    struct UpdateIssueCommentPayload: Codable {
        let issueComment: CommentNode
    }

    struct CommentNode: Codable {
        let id: String
        let body: String
        let createdAt: Date
        let updatedAt: Date
        let author: AuthorNode?

        func toComment() -> Comment {
            Comment(
                id: id,
                body: body,
                author: author?.toUser(),
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    struct AuthorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for delete comment mutation
struct DeleteCommentResponse: Codable {
    let deleteIssueComment: DeleteIssueCommentPayload

    struct DeleteIssueCommentPayload: Codable {
        let clientMutationId: String?
    }
}

// Response structure for delete issue mutation
struct DeleteIssueResponse: Codable {
    let deleteIssue: DeleteIssuePayload

    struct DeleteIssuePayload: Codable {
        let clientMutationId: String?
    }
}

// Response structure for viewer query
struct ViewerResponse: Codable {
    let viewer: ViewerNode

    struct ViewerNode: Codable {
        let login: String
    }
}

// Response structure for repositories query
struct RepositoriesResponse: Codable {
    let viewer: ViewerRepositories

    struct ViewerRepositories: Codable {
        let repositories: RepositoryConnection
    }

    struct RepositoryConnection: Codable {
        let pageInfo: PageInfo
        let nodes: [RepositoryNode]
    }

    struct PageInfo: Codable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct RepositoryNode: Codable {
        let id: String
        let name: String
        let owner: OwnerNode
        let isPrivate: Bool
        let hasIssuesEnabled: Bool
        let isArchived: Bool
        let viewerPermission: String?

        /// Issue creation fails on archived repos and on repos with the Issues tab turned off.
        var acceptsNewIssues: Bool {
            hasIssuesEnabled && !isArchived
        }

        func toRepository() -> Repository {
            return Repository(
                id: id,
                name: name,
                owner: User(
                    id: owner.login,
                    login: owner.login,
                    avatarUrl: ""
                ),
                isPrivate: isPrivate,
                isArchived: isArchived,
                viewerPermission: viewerPermission
            )
        }
    }

    struct OwnerNode: Codable {
        let login: String
    }
}

// Response structure for repository labels query
struct RepositoryLabelsResponse: Codable {
    let repository: RepositoryLabels

    struct RepositoryLabels: Codable {
        let labels: LabelConnection
    }

    struct LabelConnection: Codable {
        let pageInfo: PageInfo
        let nodes: [LabelNode]
    }

    struct PageInfo: Codable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            return Label(id: id, name: name, color: color)
        }
    }
}

// Response structure for add labels mutation
struct AddLabelsResponse: Codable {
    let addLabelsToLabelable: AddLabelsPayload

    struct AddLabelsPayload: Codable {
        let clientMutationId: String?
    }
}

// Response structure for remove labels mutation
struct RemoveLabelsResponse: Codable {
    let removeLabelsFromLabelable: RemoveLabelsPayload

    struct RemoveLabelsPayload: Codable {
        let clientMutationId: String?
    }
}

// Response structure for createLabel mutation
struct CreateLabelResponse: Codable {
    let createLabel: CreateLabelPayload

    struct CreateLabelPayload: Codable {
        let label: LabelNode?
    }

    struct LabelNode: Codable {
        let id: String
        let name: String
        let color: String

        func toLabel() -> Label {
            return Label(id: id, name: name, color: color)
        }
    }
}

// Response structure for repository collaborators query
struct RepositoryCollaboratorsResponse: Codable {
    let repository: RepositoryCollaborators

    struct RepositoryCollaborators: Codable {
        let collaborators: CollaboratorsConnection?
    }

    struct CollaboratorsConnection: Codable {
        let pageInfo: PageInfo
        let nodes: [CollaboratorNode]
    }

    struct PageInfo: Codable {
        let hasNextPage: Bool
        let endCursor: String?
    }

    struct CollaboratorNode: Codable {
        let id: String
        let login: String
        let avatarUrl: String?

        func toUser() -> User {
            User(id: id, login: login, avatarUrl: avatarUrl)
        }
    }
}

// Response structure for add assignees mutation
struct AddAssigneesResponse: Codable {
    let addAssigneesToAssignable: AddAssigneesPayload

    struct AddAssigneesPayload: Codable {
        let clientMutationId: String?
    }
}

// Response structure for remove assignees mutation
struct RemoveAssigneesResponse: Codable {
    let removeAssigneesFromAssignable: RemoveAssigneesPayload

    struct RemoveAssigneesPayload: Codable {
        let clientMutationId: String?
    }
}
