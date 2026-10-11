//
//  GitHubAPIService.swift
//  GitIssues
//
//  Created by Claude Code
//

import Foundation

class GitHubAPIService {
    private static let userAgent: String = {
        let bid = Bundle.main.bundleIdentifier ?? "GitIssues"
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "GitIssues/\(ver) (\(bid); build \(build))"
    }()

    private let graphQLClient: GraphQLClient
    private let accessToken: String

    init(accessToken: String) {
        self.accessToken = accessToken
        self.graphQLClient = GraphQLClient(accessToken: accessToken)
    }

    /// Fetches the authenticated user's login
    /// - Returns: The viewer's GitHub login
    func fetchViewerLogin() async throws -> String {
        let response: ViewerResponse = try await graphQLClient.execute(
            query: GraphQLQueries.viewerQuery,
            variables: nil
        )
        return response.viewer.login
    }

    /// Fetches all issues involving the authenticated user using search
    /// - Parameters:
    ///   - states: Filter by issue state (open, closed, or nil for all)
    ///   - repositoryFullNames: Filter by specific repositories (e.g., ["owner/repo1", "owner/repo2"])
    ///   - visibility: Filter by repository visibility (public, private, or nil for all)
    ///   - cursor: Pagination cursor for fetching next page
    /// - Returns: Array of issues and pagination info
    func fetchIssues(
        states: [IssueState]? = nil,
        repositoryFullNames: [String]? = nil,
        visibility: String? = nil,
        cursor: String? = nil
    ) async throws -> (issues: [Issue], hasNextPage: Bool, endCursor: String?) {
        // Build search query string
        var queryParts = ["involves:@me", "sort:updated-desc"]

        // Exclude archived (read-only) repositories unless the user has opted in.
        if !AppStateService.allowReadOnlyRepoAccess {
            queryParts.append("archived:false")
        }

        // Add state filter
        if let states = states {
            let stateStrings = states.map { state -> String in
                switch state {
                case .open: return "is:open"
                case .closed: return "is:closed"
                }
            }
            if stateStrings.count == 1 {
                queryParts.append(stateStrings[0])
            }
            // If both open and closed, don't add state filter (shows all)
        }

        // Add repository filter
        if let repos = repositoryFullNames, !repos.isEmpty {
            let repoQuery = repos.map { "repo:\($0)" }.joined(separator: " ")
            queryParts.append(repoQuery)
        }

        // Add visibility filter
        if let visibility = visibility {
            queryParts.append("is:\(visibility)")
        }

        let searchQuery = queryParts.joined(separator: " ")

        var variables: [String: Any] = ["query": searchQuery]

        if let cursor = cursor {
            variables["cursor"] = cursor
        }

        let response: AllIssuesResponse = try await graphQLClient.execute(
            query: GraphQLQueries.allIssuesQuery,
            variables: variables
        )

        // Filter out nil nodes (non-Issue types like PRs that don't match the inline fragment)
        let issues = response.search.nodes.compactMap { $0?.toIssue() }
        let pageInfo = response.search.pageInfo

        return (issues, pageInfo.hasNextPage, pageInfo.endCursor)
    }

    /// Fetches all issues across all pages
    /// - Parameters:
    ///   - states: Filter by issue state (open, closed, or nil for all)
    ///   - repositoryFullNames: Filter by specific repositories (e.g., ["owner/repo1", "owner/repo2"])
    ///   - visibility: Filter by repository visibility (public, private, or nil for all)
    /// - Returns: Array of all issues
    func fetchAllIssues(
        states: [IssueState]? = nil,
        repositoryFullNames: [String]? = nil,
        visibility: String? = nil
    ) async throws -> [Issue] {
        var allIssues: [Issue] = []
        var seenIDs = Set<String>()
        var cursor: String? = nil
        var hasNextPage = true

        while hasNextPage {
            let (issues, nextPage, nextCursor) = try await fetchIssues(
                states: states,
                repositoryFullNames: repositoryFullNames,
                visibility: visibility,
                cursor: cursor
            )

            // Deduplicate: GitHub search results can shift between pages (e.g. when cloning
            // changes updatedAt timestamps mid-pagination), causing the same issue to appear
            // on multiple pages.
            for issue in issues where seenIDs.insert(issue.id).inserted {
                allIssues.append(issue)
            }
            hasNextPage = nextPage
            cursor = nextCursor
        }

        return allIssues
    }

    /// Fetches a specific issue with its comments
    /// - Parameters:
    ///   - owner: Repository owner login
    ///   - repo: Repository name
    ///   - number: Issue number
    /// - Returns: Issue and its comments
    func fetchIssueDetail(
        owner: String,
        repo: String,
        number: Int
    ) async throws -> (issue: Issue, comments: [Comment]) {
        let variables: [String: Any] = [
            "owner": owner,
            "repo": repo,
            "number": number
        ]

        let response: IssueDetailResponse = try await graphQLClient.execute(
            query: GraphQLQueries.issueDetailQuery,
            variables: variables
        )

        let issue = response.repository.issue.toIssue()
        let comments = response.repository.issue.toComments()

        return (issue, comments)
    }

    /// Fetches an issue's activity log: label/assignee/state changes, renames, cross-references, ...
    /// Comments are not included. Events are returned oldest-first.
    func fetchIssueActivity(owner: String, repo: String, number: Int) async throws -> [IssueActivity] {
        let variables: [String: Any] = [
            "owner": owner,
            "repo": repo,
            "number": number
        ]

        // The log is supplementary: one event we can't read must not hide all the others.
        let response: IssueActivityResponse = try await graphQLClient.execute(
            query: GraphQLQueries.issueActivityQuery,
            variables: variables,
            tolerateErrors: true
        )

        return response.repository.issue.timelineItems.nodes
            .compactMap { $0.toActivity() }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Creates a new issue in a repository
    /// - Parameters:
    ///   - repositoryId: The ID of the repository
    ///   - title: The issue title
    ///   - body: The issue body (optional)
    ///   - labelIds: Array of label IDs to add (optional)
    /// - Returns: The created Issue
    func createIssue(
        repositoryId: String,
        title: String,
        body: String?,
        labelIds: [String]? = nil
    ) async throws -> Issue {
        // Validate inputs
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw NSError(domain: "GitHubAPIService", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Title cannot be empty"
            ])
        }

        // Prepare body - convert empty string to nil
        let trimmedBody = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalBody = (trimmedBody?.isEmpty ?? true) ? nil : trimmedBody

        var variables: [String: Any] = [
            "repositoryId": repositoryId,
            "title": trimmedTitle
        ]

        if let finalBody = finalBody {
            variables["body"] = finalBody
        }

        if let labelIds = labelIds, !labelIds.isEmpty {
            variables["labelIds"] = labelIds
        }

        let response: CreateIssueResponse = try await graphQLClient.execute(
            query: GraphQLQueries.createIssueMutation,
            variables: variables
        )

        return response.createIssue.issue.toIssue()
    }

    /// Updates an existing issue
    /// - Parameters:
    ///   - issueId: The ID of the issue to update
    ///   - title: The new title (optional)
    ///   - body: The new body (optional)
    ///   - state: The new state (optional)
    /// - Returns: The updated Issue
    func updateIssue(
        issueId: String,
        title: String?,
        body: String?,
        state: IssueState?
    ) async throws -> Issue {
        var variables: [String: Any] = ["id": issueId]

        // Validate and add title if provided
        if let title = title {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty else {
                throw NSError(domain: "GitHubAPIService", code: 400, userInfo: [
                    NSLocalizedDescriptionKey: "Title cannot be empty"
                ])
            }
            variables["title"] = trimmedTitle
        }

        // Add body if provided (convert empty to nil)
        if let body = body {
            let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalBody = trimmedBody.isEmpty ? nil : trimmedBody
            variables["body"] = finalBody
        }

        // Add state if provided
        if let state = state {
            variables["state"] = state.rawValue
        }

        let response: UpdateIssueResponse = try await graphQLClient.execute(
            query: GraphQLQueries.updateIssueMutation,
            variables: variables
        )

        return response.updateIssue.issue.toIssue()
    }

    /// Adds a comment to an issue
    /// - Parameters:
    ///   - issueId: The ID of the issue to comment on
    ///   - body: The comment body
    /// - Returns: The created Comment
    func addComment(
        issueId: String,
        body: String
    ) async throws -> Comment {
        // Validate inputs
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw NSError(domain: "GitHubAPIService", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Comment cannot be empty"
            ])
        }

        let variables: [String: Any] = [
            "subjectId": issueId,
            "body": trimmedBody
        ]

        let response: AddCommentResponse = try await graphQLClient.execute(
            query: GraphQLQueries.addCommentMutation,
            variables: variables
        )

        return response.addComment.commentEdge.node.toComment()
    }

    /// Updates an existing comment
    /// - Parameters:
    ///   - commentId: The ID of the comment to update
    ///   - body: The new comment body
    /// - Returns: The updated Comment
    func updateComment(
        commentId: String,
        body: String
    ) async throws -> Comment {
        // Validate inputs
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else {
            throw NSError(domain: "GitHubAPIService", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Comment cannot be empty"
            ])
        }

        let variables: [String: Any] = [
            "id": commentId,
            "body": trimmedBody
        ]

        let response: UpdateCommentResponse = try await graphQLClient.execute(
            query: GraphQLQueries.updateCommentMutation,
            variables: variables
        )

        return response.updateIssueComment.issueComment.toComment()
    }

    /// Deletes a comment
    /// - Parameter commentId: The ID of the comment to delete
    func deleteComment(commentId: String) async throws {
        let variables: [String: Any] = [
            "id": commentId
        ]

        let _: DeleteCommentResponse = try await graphQLClient.execute(
            query: GraphQLQueries.deleteCommentMutation,
            variables: variables
        )
    }

    /// Fetches repositories the authenticated user can open issues in, including
    /// organisation-owned ones. Repos that reject new issues are omitted.
    /// - Parameter cursor: Pagination cursor for fetching next page
    /// - Returns: Array of repositories and pagination info
    func fetchRepositories(cursor: String? = nil) async throws -> (repositories: [Repository], hasNextPage: Bool, endCursor: String?) {
        var variables: [String: Any] = [:]

        if let cursor = cursor {
            variables["cursor"] = cursor
        }

        let response: RepositoriesResponse = try await graphQLClient.execute(
            query: GraphQLQueries.repositoriesQuery,
            variables: variables
        )

        // Only repos that accept new issues and that the viewer can write to are valid
        // destinations / selections (archived or read-only repos reject issue creation).
        let repositories = response.viewer.repositories.nodes
            .filter { $0.acceptsNewIssues }
            .map { $0.toRepository() }
            .filter { !$0.isReadOnly }
        let pageInfo = response.viewer.repositories.pageInfo

        return (repositories, pageInfo.hasNextPage, pageInfo.endCursor)
    }

    /// Fetches all repositories across all pages
    /// - Returns: Array of all repositories
    func fetchAllRepositories() async throws -> [Repository] {
        var allRepositories: [Repository] = []
        var cursor: String? = nil
        var hasNextPage = true

        while hasNextPage {
            let (repositories, nextPage, nextCursor) = try await fetchRepositories(cursor: cursor)
            allRepositories.append(contentsOf: repositories)
            hasNextPage = nextPage
            cursor = nextCursor
        }

        return allRepositories
    }

    /// Deletes an issue
    /// - Parameter issueId: The ID of the issue to delete
    func deleteIssue(issueId: String) async throws {
        let variables: [String: Any] = [
            "id": issueId
        ]

        let _: DeleteIssueResponse = try await graphQLClient.execute(
            query: GraphQLQueries.deleteIssueMutation,
            variables: variables
        )
    }

    /// Fetches labels for a repository
    /// - Parameters:
    ///   - owner: Repository owner login
    ///   - repo: Repository name
    ///   - cursor: Pagination cursor
    /// - Returns: Array of labels and pagination info
    func fetchRepositoryLabels(owner: String, repo: String, cursor: String? = nil) async throws -> (labels: [Label], hasNextPage: Bool, endCursor: String?) {
        var variables: [String: Any] = [
            "owner": owner,
            "repo": repo
        ]

        if let cursor = cursor {
            variables["cursor"] = cursor
        }

        let response: RepositoryLabelsResponse = try await graphQLClient.execute(
            query: GraphQLQueries.repositoryLabelsQuery,
            variables: variables
        )

        let labels = response.repository.labels.nodes.map { $0.toLabel() }
        let pageInfo = response.repository.labels.pageInfo

        return (labels, pageInfo.hasNextPage, pageInfo.endCursor)
    }

    /// Fetches all labels for a repository across all pages
    /// - Parameters:
    ///   - owner: Repository owner login
    ///   - repo: Repository name
    /// - Returns: Array of all labels
    func fetchAllRepositoryLabels(owner: String, repo: String) async throws -> [Label] {
        var allLabels: [Label] = []
        var cursor: String? = nil
        var hasNextPage = true

        while hasNextPage {
            let (labels, nextPage, nextCursor) = try await fetchRepositoryLabels(
                owner: owner,
                repo: repo,
                cursor: cursor
            )
            allLabels.append(contentsOf: labels)
            hasNextPage = nextPage
            cursor = nextCursor
        }

        return allLabels
    }

    /// Creates a new label in a repository
    /// - Parameters:
    ///   - repositoryId: The node ID of the repository
    ///   - name: Label name
    ///   - color: 6-character hex color without leading #
    /// - Returns: The created Label
    func createLabel(repositoryId: String, name: String, color: String) async throws -> Label {
        let variables: [String: Any] = [
            "repositoryId": repositoryId,
            "name": name,
            "color": color
        ]

        let response: CreateLabelResponse = try await graphQLClient.execute(
            query: GraphQLQueries.createLabelMutation,
            variables: variables
        )

        guard let node = response.createLabel.label else {
            throw NSError(domain: "GitHubAPIService", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Label created but no data returned"
            ])
        }
        return node.toLabel()
    }

    /// Adds labels to an issue
    /// - Parameters:
    ///   - issueId: The ID of the issue
    ///   - labelIds: Array of label IDs to add
    func addLabelsToIssue(issueId: String, labelIds: [String]) async throws {
        let variables: [String: Any] = [
            "issueId": issueId,
            "labelIds": labelIds
        ]

        let _: AddLabelsResponse = try await graphQLClient.execute(
            query: GraphQLQueries.addLabelsToIssueMutation,
            variables: variables
        )
    }

    /// Removes labels from an issue
    /// - Parameters:
    ///   - issueId: The ID of the issue
    ///   - labelIds: Array of label IDs to remove
    func removeLabelsFromIssue(issueId: String, labelIds: [String]) async throws {
        let variables: [String: Any] = [
            "issueId": issueId,
            "labelIds": labelIds
        ]

        let _: RemoveLabelsResponse = try await graphQLClient.execute(
            query: GraphQLQueries.removeLabelsFromIssueMutation,
            variables: variables
        )
    }

    /// Fetches collaborators for a repository (one page)
    func fetchCollaborators(owner: String, repo: String, cursor: String? = nil) async throws -> (users: [User], hasNextPage: Bool, endCursor: String?) {
        var variables: [String: Any] = [
            "owner": owner,
            "repo": repo
        ]
        if let cursor = cursor {
            variables["cursor"] = cursor
        }

        let response: RepositoryCollaboratorsResponse = try await graphQLClient.execute(
            query: GraphQLQueries.repositoryCollaboratorsQuery,
            variables: variables
        )

        guard let collaborators = response.repository.collaborators else {
            return ([], false, nil)
        }

        let users = collaborators.nodes.map { $0.toUser() }
        let pageInfo = collaborators.pageInfo
        return (users, pageInfo.hasNextPage, pageInfo.endCursor)
    }

    /// Fetches all collaborators for a repository across all pages
    func fetchAllCollaborators(owner: String, repo: String) async throws -> [User] {
        var allUsers: [User] = []
        var cursor: String? = nil
        var hasNextPage = true

        while hasNextPage {
            let (users, nextPage, nextCursor) = try await fetchCollaborators(owner: owner, repo: repo, cursor: cursor)
            allUsers.append(contentsOf: users)
            hasNextPage = nextPage
            cursor = nextCursor
        }

        return allUsers
    }

    /// Updates assignees for an issue — adds new ones and removes dropped ones
    func setIssueAssignees(issueId: String, currentAssigneeIds: [String], newAssigneeIds: [String]) async throws {
        let currentSet = Set(currentAssigneeIds)
        let newSet = Set(newAssigneeIds)
        let toAdd = Array(newSet.subtracting(currentSet))
        let toRemove = Array(currentSet.subtracting(newSet))

        if !toAdd.isEmpty {
            let variables: [String: Any] = [
                "assignableId": issueId,
                "assigneeIds": toAdd
            ]
            let _: AddAssigneesResponse = try await graphQLClient.execute(
                query: GraphQLQueries.addAssigneesToIssueMutation,
                variables: variables
            )
        }

        if !toRemove.isEmpty {
            let variables: [String: Any] = [
                "assignableId": issueId,
                "assigneeIds": toRemove
            ]
            let _: RemoveAssigneesResponse = try await graphQLClient.execute(
                query: GraphQLQueries.removeAssigneesFromIssueMutation,
                variables: variables
            )
        }
    }

    // MARK: - Cross-Repository Transfer

    /// Finds or creates labels in the destination repository matching the given source labels by name.
    /// Existing labels are matched case-insensitively; missing labels are created with the source color.
    /// - Returns: The destination repository's labels corresponding to each source label.
    private func resolveLabels(in destination: Repository, matching sourceLabels: [Label]) async throws -> [Label] {
        guard !sourceLabels.isEmpty else { return [] }

        let existing = try await fetchAllRepositoryLabels(owner: destination.owner.login, repo: destination.name)
        var byName = Dictionary(existing.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

        var resolved: [Label] = []
        for source in sourceLabels {
            let key = source.name.lowercased()
            if let match = byName[key] {
                resolved.append(match)
            } else {
                let created = try await createLabel(repositoryId: destination.id, name: source.name, color: source.color)
                byName[key] = created
                resolved.append(created)
            }
        }
        return resolved
    }

    /// Finds a label by name in a repository, creating it if it doesn't exist. Case-insensitive match.
    /// Used to ensure a Kanban state label (`kanban-<Status>`) exists before assigning it.
    /// - Returns: The existing or newly created label.
    func ensureLabel(in repository: Repository, name: String, color: String) async throws -> Label {
        let existing = try await fetchAllRepositoryLabels(owner: repository.owner.login, repo: repository.name)
        if let match = existing.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return match
        }
        return try await createLabel(repositoryId: repository.id, name: name, color: color)
    }

    /// Copies an issue into the destination repository, transferring the title, description,
    /// labels and all comments. The copy is created fresh, so its creation timestamps and author
    /// reflect the current user and time (use `moveIssue` to preserve the original timestamps).
    /// - Returns: The newly created issue in the destination repository.
    func copyIssue(_ issue: Issue, to destination: Repository) async throws -> Issue {
        let (_, comments) = try await fetchIssueDetail(
            owner: issue.repository.owner.login,
            repo: issue.repository.name,
            number: issue.number
        )

        let labels = try await resolveLabels(in: destination, matching: issue.labels)

        var newIssue = try await createIssue(
            repositoryId: destination.id,
            title: issue.title,
            body: issue.body,
            labelIds: labels.map { $0.id }
        )

        for comment in comments where !comment.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = try await addComment(issueId: newIssue.id, body: comment.body)
        }

        // Preserve the original open/closed state.
        if issue.state == .closed {
            newIssue = try await updateIssue(issueId: newIssue.id, title: nil, body: nil, state: .closed)
        }

        return newIssue
    }

    /// Moves an issue into the destination repository, transferring the title, description, labels
    /// and all comments while preserving the creation timestamps of the issue and each comment via
    /// GitHub's issue import API. The original issue is deleted once the import succeeds.
    /// - Returns: The newly created issue in the destination repository.
    func moveIssue(_ issue: Issue, to destination: Repository) async throws -> Issue {
        let (_, comments) = try await fetchIssueDetail(
            owner: issue.repository.owner.login,
            repo: issue.repository.name,
            number: issue.number
        )

        // Labels are imported by name, so make sure they exist in the destination first.
        let labels = try await resolveLabels(in: destination, matching: issue.labels)

        let number = try await importIssue(
            destination: destination,
            issue: issue,
            comments: comments,
            labelNames: labels.map { $0.name }
        )

        let (newIssue, _) = try await fetchIssueDetail(
            owner: destination.owner.login,
            repo: destination.name,
            number: number
        )

        // Only remove the original after the new issue is confirmed present.
        try await deleteIssue(issueId: issue.id)

        return newIssue
    }

    /// Imports an issue (with preserved timestamps) into the destination repository using GitHub's
    /// asynchronous issue import API, polling until the import completes.
    /// - Returns: The number of the newly imported issue.
    private func importIssue(
        destination: Repository,
        issue: Issue,
        comments: [Comment],
        labelNames: [String]
    ) async throws -> Int {
        guard let url = URL(string: "https://api.github.com/repos/\(destination.owner.login)/\(destination.name)/import/issues") else {
            throw GraphQLError.invalidURL
        }

        let formatter = ISO8601DateFormatter()

        var issueDict: [String: Any] = [
            "title": issue.title,
            "body": issue.body ?? "",
            "created_at": formatter.string(from: issue.createdAt),
            "closed": issue.state == .closed
        ]
        if !labelNames.isEmpty {
            issueDict["labels"] = labelNames
        }

        var payload: [String: Any] = ["issue": issueDict]
        if !comments.isEmpty {
            payload["comments"] = comments.map { comment in
                [
                    "created_at": formatter.string(from: comment.createdAt),
                    "body": comment.body
                ]
            }
        }

        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        let data = try await performRESTRequest(url: url, method: "POST", body: bodyData)

        let decoder = JSONDecoder()
        let initial = try decoder.decode(IssueImportResponse.self, from: data)
        AppLogger.shared.debug("Issue import started for \(destination.fullName) (initial status: \(initial.status ?? "nil"))")

        guard let statusURLString = initial.url, let statusURL = URL(string: statusURLString) else {
            throw GraphQLError.serverError("Issue import did not return a status URL")
        }

        // Poll the import status until it resolves. Imports are usually quick but can be queued,
        // so allow up to ~90s (2s between polls) before giving up.
        var lastStatus = initial.status ?? "pending"
        for attempt in 0..<45 {
            try await Task.sleep(nanoseconds: 2_000_000_000)

            let statusData = try await performRESTRequest(url: statusURL, method: "GET", body: nil)
            let status = try decoder.decode(IssueImportResponse.self, from: statusData)
            lastStatus = status.status ?? "nil"
            AppLogger.shared.debug("Issue import poll #\(attempt + 1): status=\(lastStatus)")

            switch status.status {
            case "imported":
                guard let issueURL = status.issueUrl,
                      let last = issueURL.split(separator: "/").last,
                      let number = Int(last) else {
                    throw GraphQLError.serverError("Could not determine the imported issue number")
                }
                return number
            case "failed":
                let detail = status.errors?.compactMap { $0.code }.joined(separator: ", ")
                AppLogger.shared.error("Issue import failed for \(destination.fullName): \(detail ?? "unknown error")")
                throw GraphQLError.serverError("Issue import failed\(detail.map { ": \($0)" } ?? "")")
            default:
                // "pending" / "importing" — keep polling.
                continue
            }
        }

        AppLogger.shared.error("Issue import timed out for \(destination.fullName) (last status: \(lastStatus))")
        throw GraphQLError.serverError("Issue import timed out (last status: \(lastStatus))")
    }

    /// Performs a REST request against the GitHub API using the issue-import preview media type.
    private func performRESTRequest(url: URL, method: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/vnd.github.golden-comet-preview+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpBody = body
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw GraphQLError.unauthorized
            }
            if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let resetStr = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                let resetDate = resetStr.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
                throw GraphQLError.rateLimited(reset: resetDate)
            }
            guard (200...299).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                throw GraphQLError.serverError("HTTP \(http.statusCode): \(message)")
            }
        }

        return data
    }

    /// Renders markdown text to HTML using GitHub's rendering API
    /// - Parameter markdown: The markdown text to render
    /// - Returns: Rendered HTML string
    func renderMarkdown(_ markdown: String) async throws -> String {
        guard let url = URL(string: "https://api.github.com/markdown") else {
            throw NSError(domain: "GitHubAPIService", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "Invalid URL"
            ])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "text": markdown,
            "mode": "gfm"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 {
                throw GraphQLError.unauthorized
            }
            if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let resetStr = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                let resetDate = resetStr.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
                throw GraphQLError.rateLimited(reset: resetDate)
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "GitHubAPIService", code: 500, userInfo: [
                NSLocalizedDescriptionKey: "Failed to decode HTML response"
            ])
        }

        return html
    }
}

/// Response shape for GitHub's issue import API (both the initial POST and the status polling GET).
private struct IssueImportResponse: Codable {
    let url: String?
    let status: String?
    let issueUrl: String?
    let errors: [ImportError]?

    enum CodingKeys: String, CodingKey {
        case url
        case status
        case issueUrl = "issue_url"
        case errors
    }

    struct ImportError: Codable {
        let code: String?
        let field: String?
        let resource: String?
        let location: String?
    }
}
