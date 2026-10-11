//
//  IssueDetailView.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI
import Combine

struct IssueDetailView: View {
    @State private var activeCommentWindowId: UUID?
    @State private var activeIssueFormWindowId: UUID?

    @ObservedObject var viewModel: IssueDetailViewModel
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject var authManager: OAuth2Manager
    @StateObject private var coordinator = WindowCoordinator.shared
    @State private var showDeleteConfirmation = false
    @State private var commentToDelete: Comment?
    @State private var showDeleteIssueConfirmation = false
    @State private var showAssignSheet = false
    @State private var isShareAnimating = false
    @AppStorage(AppStateService.showIssueActivityKey) private var showActivity = true
    @State private var cancellables = Set<AnyCancellable>()

    /// Opens the Add Comment window. Shared by the link at the top of the panel (next to the
    /// issue author) and the one below the comments.
    private func addComment() {
        if let accessToken = authManager.getAccessToken() {
            let windowData = CommentFormWindowData(
                mode: .add,
                accessToken: accessToken,
                issueId: viewModel.issue.id,
                issueState: viewModel.issue.state.rawValue
            )
            openWindow(id: WindowIdentifier.commentForm.rawValue, value: windowData)
            activeCommentWindowId = windowData.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                IssueHeaderView(
                    issue: viewModel.issue,
                    isPinned: viewModel.isPinned,
                    isShareAnimating: isShareAnimating,
                    onPinToggle: {
                        viewModel.togglePin()
                    },
                    onEditTapped: {
                        if let accessToken = authManager.getAccessToken() {
                            let issueData = IssueFormWindowData.IssueData(
                                issueId: viewModel.issue.id,
                                title: viewModel.issue.title,
                                body: viewModel.issue.body,
                                state: viewModel.issue.state.rawValue,
                                repositoryId: viewModel.issue.repository.id,
                                repositoryOwner: viewModel.issue.repository.owner.login,
                                repositoryName: viewModel.issue.repository.name,
                                labelIds: viewModel.issue.labels.map { $0.id }
                            )
                            let windowData = IssueFormWindowData(
                                mode: .edit,
                                accessToken: accessToken,
                                issueData: issueData
                            )
                            openWindow(id: WindowIdentifier.issueForm.rawValue, value: windowData)
                            activeIssueFormWindowId = windowData.id
                        }
                    },
                    onAssignTapped: {
                        showAssignSheet = true
                    },
                    onDeleteTapped: {
                        showDeleteIssueConfirmation = true
                    },
                    onShareTapped: {
                        viewModel.shareIssue()
                        // Animate the share button
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isShareAnimating = true
                        }
                        // Reset after delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShareAnimating = false
                            }
                        }
                    }
                )

                Divider()

                // Metadata
                IssueMetadataView(issue: viewModel.issue)

                // Labels (Kanban state labels are hidden)
                let visibleLabels = Kanban.visibleLabels(viewModel.issue.labels)
                if !visibleLabels.isEmpty {
                    LabelsSection(labels: visibleLabels)
                }

                // Assignees
                if !viewModel.issue.assignees.isEmpty {
                    AssigneesSection(assignees: viewModel.issue.assignees)
                }

                Divider()

                // Issue body (with the hidden Kanban order marker stripped)
                IssueBodyView(
                    bodyText: KanbanOrderMarker.strip(from: viewModel.issue.body),
                    author: viewModel.issue.author,
                    apiService: viewModel.apiService,
                    onAddComment: addComment
                )

                // Comments section
                CommentsSection(
                    comments: viewModel.comments,
                    activity: showActivity ? viewModel.activity : [],
                    activityError: showActivity ? viewModel.activityError : nil,
                    isLoading: viewModel.isLoadingComments,
                    apiService: viewModel.apiService,
                    onAddComment: addComment,
                    onEditComment: { comment in
                        if let accessToken = authManager.getAccessToken() {
                            let commentData = CommentFormWindowData.CommentData(
                                commentId: comment.id,
                                body: comment.body
                            )
                            let windowData = CommentFormWindowData(
                                mode: .edit,
                                accessToken: accessToken,
                                issueId: viewModel.issue.id,
                                issueState: viewModel.issue.state.rawValue,
                                commentData: commentData
                            )
                            openWindow(id: WindowIdentifier.commentForm.rawValue, value: windowData)
                            activeCommentWindowId = windowData.id
                        }
                    },
                    onDeleteComment: { comment in
                        commentToDelete = comment
                        showDeleteConfirmation = true
                    }
                )

                // Error message
                if let error = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                }
            }
            .padding()
        }
        .task {
            await viewModel.loadIssueDetails()

            // Subscribe to coordinator events
            coordinator.issueFormSuccess
                .sink { (windowId, issue) in
                    if issue.id == viewModel.issue.id {
                        Task {
                            // Reload details (issue + comments) for the currently displayed issue, with a short delay
                            await viewModel.loadIssueDetails(afterDelay: 0.6)
                        }
                    }
                    // No else branch needed: ContentView's issueFormSuccess handler already
                    // upserts the changed issue into the list cache immediately.
                }
                .store(in: &cancellables)

            coordinator.commentFormSuccess
            .sink { (windowId, comment) in
                guard windowId == activeCommentWindowId else { return }
                    Task {
                        await viewModel.loadIssueDetails()
                    }
                }
                .store(in: &cancellables)

            coordinator.commentFormSuccessAndClose
            .sink { (windowId, comment) in
                guard windowId == activeCommentWindowId else { return }
                    Task {
                        await viewModel.closeIssue()
                        await viewModel.loadIssueDetails()
                        // closeIssue() already updates the list cache via upsertIssueInCache
                    }
                }
                .store(in: &cancellables)
        }
        .onChange(of: showActivity) { _, _ in
            // Fetch (or clear) the log when the setting is toggled while an issue is open.
            Task { await viewModel.loadActivity() }
        }
        .alert("Delete Comment", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                commentToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let comment = commentToDelete {
                    Task {
                        await viewModel.deleteComment(comment)
                        commentToDelete = nil
                    }
                }
            }
        } message: {
            Text("Are you sure you want to delete this comment? This action cannot be undone.")
        }
        .alert("Delete Issue", isPresented: $showDeleteIssueConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                Task {
                    await viewModel.deleteIssue()
                }
            }
        } message: {
            Text("Are you sure you want to delete this issue? This action cannot be undone.")
        }
        .sheet(isPresented: $showAssignSheet) {
            AssignIssueSheet(
                issue: viewModel.issue,
                apiService: viewModel.apiService,
                onSave: { users in
                    showAssignSheet = false
                    Task { await viewModel.setAssignees(users) }
                },
                onCancel: { showAssignSheet = false }
            )
        }
    }
}

// MARK: - Issue Header
struct IssueHeaderView: View {
    let issue: Issue
    let isPinned: Bool
    let isShareAnimating: Bool
    let onPinToggle: () -> Void
    let onEditTapped: () -> Void
    let onAssignTapped: () -> Void
    let onDeleteTapped: () -> Void
    let onShareTapped: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                // State icon
                Image(systemName: issue.state == .open ? "circle" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(issue.state == .open ? .green : .purple)

                VStack(alignment: .leading, spacing: 8) {
                    // Title
                    Text(issue.title)
                        .font(.title)
                        .fontWeight(.bold)

                    // Issue number and state
                    HStack {
                        Text("#\(issue.number)")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(issue.state == .open ? "Open" : "Closed")
                            .font(.headline)
                            .foregroundColor(issue.state == .open ? .green : .purple)
                    }
                }

                Spacer()

                // Read-only repos (archived / no write access) reject all issue mutations.
                let isReadOnly = issue.repository.isReadOnly

                // Edit button
                Button(action: onEditTapped) {
                    Text("Edit")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                .buttonStyle(.bordered)
                .help(isReadOnly ? "Read-only repository" : "Edit issue")
                .disabled(isReadOnly)

                // Assign button
                Button(action: onAssignTapped) {
                    Image(systemName: "person.badge.plus")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(isReadOnly ? "Read-only repository" : "Assign issue")
                .disabled(isReadOnly)

                // Pin button
                Button(action: onPinToggle) {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.title2)
                        .foregroundColor(isPinned ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isReadOnly ? "Read-only repository" : (isPinned ? "Unpin issue" : "Pin issue"))
                .disabled(isReadOnly)

                // Delete button
                Button(action: onDeleteTapped) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help(isReadOnly ? "Read-only repository" : "Delete issue")
                .disabled(isReadOnly)

                // Share button
                Button(action: onShareTapped) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title2)
                        .foregroundColor(isShareAnimating ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("Copy GitHub URL to clipboard")
            }
        }
    }
}

// MARK: - Metadata
struct IssueMetadataView: View {
    let issue: Issue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person")
                    .foregroundColor(.secondary)
                if let author = issue.author {
                    Text(author.login)
                        .font(.subheadline)
                } else {
                    Text("Unknown")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text("opened this issue")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.secondary)
                Text("Created \(issue.createdAt, style: .relative)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text("Updated \(issue.updatedAt, style: .relative)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text(issue.repository.fullName)
                    .font(.subheadline)
            }
        }
        .font(.caption)
    }
}

// MARK: - Labels Section
struct LabelsSection: View {
    let labels: [Label]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tag")
                    .foregroundColor(.secondary)
                Text("Labels")
                    .font(.headline)
            }

            FlowLayout(spacing: 6) {
                ForEach(labels) { label in
                    LabelBadge(label: label)
                }
            }
        }
    }
}

// MARK: - Assignees Section
struct AssigneesSection: View {
    let assignees: [User]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.2")
                    .foregroundColor(.secondary)
                Text("Assignees")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(assignees) { assignee in
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(assignee.login)
                            .font(.subheadline)
                    }
                }
            }
        }
    }
}

// MARK: - Issue Body
struct IssueBodyView: View {
    let bodyText: String
    let author: User?
    let apiService: GitHubAPIService
    let onAddComment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let author = author {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(author.login)
                            .font(.headline)
                    }
                }

                // Same action as the link below the comments, so long issues don't need a scroll.
                AddCommentLink(action: onAddComment)

                Spacer()

                Text("Description")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if bodyText.isEmpty {
                Text("No description provided")
                    .foregroundColor(.secondary)
                    .italic()
                    .padding()
            } else {
                // Use GitHub markdown rendering
                MarkdownRenderView(markdown: bodyText, apiService: apiService)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
            }
        }
    }
}

/// The "+ Add Comment" link, shown above the description and below the comments.
struct AddCommentLink: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "plus.circle.fill")
                    .foregroundColor(.accentColor)
                Text("Add Comment")
                    .font(.subheadline)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Comments Section
struct CommentsSection: View {
    let comments: [Comment]
    /// GitHub activity events to interleave with the comments (empty when the setting is off).
    let activity: [IssueActivity]
    /// Why the activity log couldn't be loaded, if it couldn't.
    var activityError: String?
    let isLoading: Bool
    let apiService: GitHubAPIService
    let onAddComment: () -> Void
    let onEditComment: (Comment) -> Void
    let onDeleteComment: (Comment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bubble.left")
                    .foregroundColor(.secondary)
                Text("Comments")
                    .font(.headline)
                Text("(\(comments.count))")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            if let activityError {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Couldn't load the GitHub activity log: \(activityError)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isLoading {
                ProgressView("Loading comments...")
                    .frame(maxWidth: .infinity)
                    .padding()
            } else {
                let entries = ConversationEntry.merge(comments: comments, activity: activity)
                if entries.isEmpty {
                    Text("No comments yet")
                        .foregroundColor(.secondary)
                        .italic()
                        .padding()
                } else {
                    ForEach(entries) { entry in
                        switch entry {
                        case .comment(let comment):
                            CommentView(
                                comment: comment,
                                apiService: apiService,
                                onEdit: {
                                    onEditComment(comment)
                                },
                                onDelete: {
                                    onDeleteComment(comment)
                                }
                            )
                        case .activity(let event):
                            ActivityEventView(event: event)
                        }
                    }
                }
            }

            // Add comment button
            AddCommentLink(action: onAddComment)
                .padding(.top, 8)
        }
    }
}

// MARK: - Activity Event
/// A compact one-line entry in the activity log, e.g. "alice closed this as completed · 2 days ago".
struct ActivityEventView: View {
    let event: IssueActivity

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.systemImage)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18)

            HStack(spacing: 4) {
                Text(event.actor?.login ?? "Someone")
                    .font(.caption)
                    .fontWeight(.semibold)

                switch event.kind {
                case .labeled(let label):
                    Text("added the")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LabelBadge(label: label)
                    Text("label")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .unlabeled(let label):
                    Text("removed the")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    LabelBadge(label: label)
                    Text("label")
                        .font(.caption)
                        .foregroundColor(.secondary)
                default:
                    Text(event.phrase)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Text(event.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }
}

// MARK: - Comment View
struct CommentView: View {
    let comment: Comment
    let apiService: GitHubAPIService
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .foregroundColor(.accentColor)

                if let author = comment.author {
                    Text(author.login)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text("Unknown")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }

                Text("commented")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(comment.createdAt, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Edit button
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit comment")

                // Delete button
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash.circle")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete comment")
            }

            // Use GitHub markdown rendering
            MarkdownRenderView(markdown: comment.body, apiService: apiService)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(8)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

// MARK: - Flow Layout for Labels
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }

    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)

                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }

                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }

            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

