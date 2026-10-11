//
//  ContentView.swift
//  GitIssues
//
//  Created by Nick Elsey on 21/1/2026.
//

import SwiftUI
import Combine
import AppKit

struct ContentView: View {
    @EnvironmentObject var authManager: OAuth2Manager
    @Environment(\.openWindow) private var openWindow
    @StateObject private var viewModel: IssuesListViewModelWrapper
    @StateObject private var coordinator = WindowCoordinator.shared
    @State private var searchText = ""
    @State private var selectedIssues: Set<Issue> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var issueToDelete: Issue?
    @State private var issueToAssign: Issue?
    @State private var issueForLabels: Issue?
    @State private var showDeleteConfirmation = false
    @State private var sidebarWidth: CGFloat?
    @State private var windowWidth: CGFloat = 1200
    @State private var cancellables = Set<AnyCancellable>()
    @State private var scrollToIssueID: String?
    @AppStorage("kanbanViewEnabled") private var kanbanViewEnabled = false
    // Batch operation state
    @State private var batchOpIssues: Set<Issue> = []
    @State private var showBatchDeleteConfirmation = false
    @State private var showBatchCloseConfirmation = false
    @State private var showBatchCloneConfirmation = false
    @State private var showBatchAssignSheet = false
    // Copy/move to another repository
    @State private var transferRequest: TransferRequest?

    var singleSelectedIssue: Issue? {
        selectedIssues.count == 1 ? selectedIssues.first : nil
    }

    /// Issue-action closures shared by the list rows' context menu and the Kanban board cards.
    private var issueActions: IssueActions {
        IssueActions(
            edit: { issue in
                if let accessToken = authManager.getAccessToken() {
                    let issueData = IssueFormWindowData.IssueData(
                        issueId: issue.id,
                        title: issue.title,
                        body: issue.body,
                        state: issue.state.rawValue,
                        repositoryId: issue.repository.id,
                        repositoryOwner: issue.repository.owner.login,
                        repositoryName: issue.repository.name,
                        labelIds: issue.labels.map { $0.id }
                    )
                    let windowData = IssueFormWindowData(mode: .edit, accessToken: accessToken, issueData: issueData)
                    openWindow(id: WindowIdentifier.issueForm.rawValue, value: windowData)
                }
            },
            clone: { issue in Task { await viewModel.viewModel?.cloneIssue(issue) } },
            assign: { issue in issueToAssign = issue },
            editLabels: { issue in issueForLabels = issue },
            copyToRepo: { issues in transferRequest = TransferRequest(mode: .copy, issues: issues) },
            moveToRepo: { issues in transferRequest = TransferRequest(mode: .move, issues: issues) },
            close: { issue in Task { await viewModel.viewModel?.closeIssue(issue) } },
            reopen: { issue in Task { await viewModel.viewModel?.reopenIssue(issue) } },
            delete: { issue in
                issueToDelete = issue
                showDeleteConfirmation = true
            },
            batchClone: { sel in
                batchOpIssues = sel
                showBatchCloneConfirmation = true
            },
            batchAssign: { sel in
                batchOpIssues = sel
                showBatchAssignSheet = true
            },
            batchClose: { sel in
                batchOpIssues = sel
                showBatchCloseConfirmation = true
            },
            batchDelete: { sel in
                batchOpIssues = sel
                showBatchDeleteConfirmation = true
            }
        )
    }

    /// Cmd+R: background refresh. `nil` while a load is already in flight (disables the menu item).
    private var refreshAction: (() -> Void)? {
        guard let vm = viewModel.viewModel, !vm.isLoading, !vm.isRefreshing else { return nil }
        return { Task { await vm.loadIssues() } }
    }

    private let appStateService = AppStateService()

    init() {
        _viewModel = StateObject(wrappedValue: IssuesListViewModelWrapper())

        // Restore sidebar width
        let service = AppStateService()
        if let savedWidth = service.getSidebarWidth() {
            _sidebarWidth = State(initialValue: CGFloat(savedWidth))
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            VStack(spacing: 0) {
                // Title and count
                HStack {
                    Text("Issues")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("(\(viewModel.viewModel?.filteredIssues.count ?? 0))")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 8)

                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search issues...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { _, newValue in
                            viewModel.viewModel?.setSearchText(newValue)
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            viewModel.viewModel?.setSearchText("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))

                // Filter bar
                if let vm = viewModel.viewModel {
                    FilterBarView(viewModel: vm)
                }

                Divider()

                // Issues list
                Group {
                    if let vm = viewModel.viewModel {
                        if vm.isLoading {
                            ProgressView("Loading issues...")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let error = vm.errorMessage, vm.allIssues.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.orange)
                                Text("Error Loading Issues")
                                    .font(.headline)
                                Text(error)
                                    .font(.body)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                                Button("Retry") {
                                    Task {
                                        await vm.loadIssues()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if kanbanViewEnabled {
                            KanbanBoardView(
                                viewModel: vm,
                                settings: KanbanSettingsService.shared,
                                selectedIssues: $selectedIssues,
                                actions: issueActions
                            )
                        } else if vm.filteredIssues.isEmpty {
                            VStack(spacing: 16) {
                                Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                                    .font(.system(size: 48))
                                    .foregroundColor(.green)
                                Text(searchText.isEmpty ? "No Issues" : "No Results")
                                    .font(.headline)
                                Text(searchText.isEmpty
                                     ? "You don't have any issues matching the current filters."
                                     : "No issues match your search criteria.")
                                    .font(.body)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { proxy in
                            List(vm.filteredIssues, selection: $selectedIssues) { issue in
                                IssueRow(
                                    issue: issue,
                                    isPinned: vm.isPinned(issue.id),
                                    onPinToggle: {
                                        vm.togglePin(for: issue.id)
                                    }
                                )
                                .tag(issue)
                                .contextMenu {
                                    issueContextMenu(for: issue, selection: selectedIssues, actions: issueActions)
                                }
                                // Double-click opens the editor (simultaneous so the first click
                                // still selects the row).
                                .simultaneousGesture(
                                    TapGesture(count: 2).onEnded {
                                        guard !issue.repository.isReadOnly else { return }
                                        selectedIssues = [issue]
                                        issueActions.edit(issue)
                                    }
                                )
                            }
                            .listStyle(.sidebar)
                            .onKeyPress(.return) {
                                if let selected = singleSelectedIssue,
                                   let accessToken = authManager.getAccessToken() {
                                    let issueData = IssueFormWindowData.IssueData(
                                        issueId: selected.id,
                                        title: selected.title,
                                        body: selected.body,
                                        state: selected.state.rawValue,
                                        repositoryId: selected.repository.id,
                                        repositoryOwner: selected.repository.owner.login,
                                        repositoryName: selected.repository.name,
                                        labelIds: selected.labels.map { $0.id }
                                    )
                                    let windowData = IssueFormWindowData(
                                        mode: .edit,
                                        accessToken: accessToken,
                                        issueData: issueData
                                    )
                                    openWindow(id: WindowIdentifier.issueForm.rawValue, value: windowData)
                                    return .handled
                                }
                                return .ignored
                            }
                            .onChange(of: scrollToIssueID) { _, newID in
                                guard let id = newID else { return }
                                scrollToIssueID = nil
                                DispatchQueue.main.async {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                            } // end ScrollViewReader
                        }
                    } else {
                        ProgressView("Initializing...")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .navigationTitle("GitIssues")
            .navigationSplitViewColumnWidth(
                min: 400,
                ideal: sidebarWidth ?? 600,
                max: max(800, windowWidth * 0.8)
            )
            .toolbar(content: {
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        if let accessToken = authManager.getAccessToken() {
                            let windowData = IssueFormWindowData(mode: .create, accessToken: accessToken)
                            openWindow(id: WindowIdentifier.issueForm.rawValue, value: windowData)
                        }
                    } label: {
                        SwiftUI.Label("New Issue", systemImage: "plus")
                    }
                    .disabled(viewModel.viewModel == nil)
                    .help("Create new issue")

                    Button {
                        Task { await viewModel.viewModel?.loadIssues() }
                    } label: {
                        if viewModel.viewModel?.isRefreshing == true {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.viewModel?.isLoading == true || viewModel.viewModel?.isRefreshing == true)
                    .help("Refresh issues")

                    Button {
                        authManager.signOut()
                    } label: {
                        Text("Sign Out")
                    }
                }
            })
        } detail: {
            // Detail view
            if selectedIssues.count > 1,
               let vm = viewModel.viewModel {
                MultiSelectDetailView(
                    selectedIssues: selectedIssues,
                    onBatchClone: {
                        batchOpIssues = selectedIssues
                        showBatchCloneConfirmation = true
                    },
                    onBatchAssign: {
                        batchOpIssues = selectedIssues
                        showBatchAssignSheet = true
                    },
                    onBatchCopy: {
                        transferRequest = TransferRequest(mode: .copy, issues: Array(selectedIssues))
                    },
                    onBatchMove: {
                        transferRequest = TransferRequest(mode: .move, issues: Array(selectedIssues))
                    },
                    onBatchClose: {
                        batchOpIssues = selectedIssues
                        showBatchCloseConfirmation = true
                    },
                    onBatchDelete: {
                        batchOpIssues = selectedIssues
                        showBatchDeleteConfirmation = true
                    }
                )
                .onChange(of: vm.allIssues) { _, newIssues in
                    let byId = Dictionary(newIssues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                    selectedIssues = Set(selectedIssues.compactMap { byId[$0.id] })
                }
            } else if let issue = singleSelectedIssue,
               let accessToken = authManager.getAccessToken(),
               let vm = viewModel.viewModel {
                IssueDetailHost(issue: issue, accessToken: accessToken, listViewModel: vm)
                    .id("\(issue.id)-\(issue.updatedAt.timeIntervalSince1970)")
                    .onChange(of: vm.allIssues) { _, newIssues in
                        let byId = Dictionary(newIssues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                        selectedIssues = Set(selectedIssues.compactMap { byId[$0.id] })
                    }
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Select an issue to view details")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Initialize viewModel with actual token
            if viewModel.viewModel == nil, let accessToken = authManager.getAccessToken() {
                let newViewModel = IssuesListViewModel(accessToken: accessToken)
                viewModel.viewModel = newViewModel
                await newViewModel.loadIssues()
                newViewModel.startBackgroundSync()
            }

            // Subscribe to coordinator events
            coordinator.issueFormSuccess
                .sink { (windowId, issue) in
                    let isNew = viewModel.viewModel?.allIssues.first { $0.id == issue.id } == nil
                    // Immediately update the cache — fixes new/edited issues not appearing instantly
                    viewModel.viewModel?.upsertIssueInCache(issue)
                    if isNew {
                        // Select and scroll to newly created issues
                        selectedIssues = [issue]
                        scrollToIssueID = issue.id
                    } else if selectedIssues.first?.id == issue.id {
                        selectedIssues = [issue]
                    }
                }
                .store(in: &cancellables)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let vm = viewModel.viewModel {
                ProgressFooterView(queue: vm.taskQueue)
                    .animation(.easeInOut(duration: 0.2), value: vm.taskQueue.isProcessing)
            }
        }
        .focusedSceneValue(\.refreshIssuesAction, refreshAction)
        .background(WindowAccessor { window in
            // Use macOS native window frame autosave
            window.setFrameAutosaveName("MainWindow")
        })
        .onReceive(NotificationCenter.default.publisher(for: NSSplitView.didResizeSubviewsNotification)) { notification in
            // Save sidebar width when split view is resized
            if let splitView = notification.object as? NSSplitView,
               splitView.subviews.count > 0 {
                let width = splitView.subviews[0].frame.width
                sidebarWidth = width
                appStateService.saveSidebarWidth(Double(width))
                // Track the total window width so the left panel can grow to ~80% of it.
                if splitView.frame.width > 0 {
                    windowWidth = splitView.frame.width
                }
            }
        }
        .alert("Delete Issue", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                issueToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let issue = issueToDelete {
                    Task {
                        await viewModel.viewModel?.deleteIssue(issue)
                        selectedIssues.remove(issue)
                        issueToDelete = nil
                    }
                }
            }
        } message: {
            if let issue = issueToDelete {
                Text("Are you sure you want to delete \"\(issue.title)\"? This action cannot be undone.")
            }
        }
        // Batch delete confirmation
        .alert("Delete \(batchOpIssues.count) Issues", isPresented: $showBatchDeleteConfirmation) {
            Button("Cancel", role: .cancel) { batchOpIssues = [] }
            Button("Delete All", role: .destructive) {
                let issues = batchOpIssues
                viewModel.viewModel?.enqueueBatchDelete(Array(issues))
                selectedIssues.subtract(issues)
                batchOpIssues = []
            }
        } message: {
            Text("Permanently delete \(batchOpIssues.count) issues? This cannot be undone.")
        }
        // Batch close confirmation
        .alert("Close Issues", isPresented: $showBatchCloseConfirmation) {
            Button("Cancel", role: .cancel) { batchOpIssues = [] }
            Button("Close") {
                let issues = batchOpIssues.filter { $0.state == .open }
                viewModel.viewModel?.enqueueBatchClose(Array(issues))
                batchOpIssues = []
            }
        } message: {
            let openCount = batchOpIssues.filter { $0.state == .open }.count
            Text("Close \(openCount) open issue\(openCount == 1 ? "" : "s")?")
        }
        // Batch clone confirmation
        .alert("Clone \(batchOpIssues.count) Issues", isPresented: $showBatchCloneConfirmation) {
            Button("Cancel", role: .cancel) { batchOpIssues = [] }
            Button("Clone All") {
                let issues = batchOpIssues
                viewModel.viewModel?.enqueueBatchClone(Array(issues))
                batchOpIssues = []
            }
        } message: {
            Text("Create \(batchOpIssues.count) cloned copies of the selected issues?")
        }
        // Single-issue assign sheet
        .sheet(item: $issueToAssign) { issue in
            if let accessToken = authManager.getAccessToken() {
                AssignIssueSheet(
                    issue: issue,
                    apiService: GitHubAPIService(accessToken: accessToken),
                    onSave: { users in
                        issueToAssign = nil
                        Task { await viewModel.viewModel?.assignIssue(issue, assignees: users) }
                    },
                    onCancel: { issueToAssign = nil }
                )
            }
        }
        // Batch assign sheet
        .sheet(isPresented: $showBatchAssignSheet) {
            if let firstIssue = batchOpIssues.first,
               let accessToken = authManager.getAccessToken() {
                let issues = batchOpIssues
                AssignIssueSheet(
                    issue: firstIssue,
                    apiService: GitHubAPIService(accessToken: accessToken),
                    onSave: { users in
                        showBatchAssignSheet = false
                        viewModel.viewModel?.enqueueBatchAssign(Array(issues), assignees: users)
                        batchOpIssues = []
                    },
                    onCancel: {
                        showBatchAssignSheet = false
                        batchOpIssues = []
                    }
                )
            }
        }
        // Copy / move to another repository
        .sheet(item: $issueForLabels) { issue in
            if let vm = viewModel.viewModel {
                IssueLabelsSheet(issue: issue, viewModel: vm) {
                    issueForLabels = nil
                }
            }
        }
        .sheet(item: $transferRequest) { request in
            if let vm = viewModel.viewModel {
                TransferIssuesSheet(
                    mode: request.mode,
                    issues: request.issues,
                    viewModel: vm,
                    onComplete: {
                        transferRequest = nil
                        batchOpIssues = []
                    }
                )
            }
        }
    }
}

/// Identifiable request describing a pending copy/move-to-repository action.
struct TransferRequest: Identifiable {
    let id = UUID()
    let mode: IssueTransferMode
    let issues: [Issue]
}

struct IssueDetailHost: View {
    let issue: Issue
    let accessToken: String
    let listViewModel: IssuesListViewModel

    @StateObject private var viewModel: IssueDetailViewModel

    init(issue: Issue, accessToken: String, listViewModel: IssuesListViewModel) {
        self.issue = issue
        self.accessToken = accessToken
        self.listViewModel = listViewModel
        let apiService = GitHubAPIService(accessToken: accessToken)
        _viewModel = StateObject(wrappedValue: IssueDetailViewModel(
            issue: issue,
            apiService: apiService,
            pinningService: listViewModel.pinningService,
            listViewModel: listViewModel
        ))
    }

    var body: some View {
        IssueDetailView(viewModel: viewModel)
    }
}

struct IssueRow: View {
    let issue: Issue
    let isPinned: Bool
    let onPinToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Pin button
            Button(action: onPinToggle) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundColor(isPinned ? .accentColor : .secondary)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin issue" : "Pin issue")

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: issue.state == .open ? "circle" : "checkmark.circle.fill")
                        .foregroundColor(issue.state == .open ? .green : .purple)

                    Text(issue.title)
                        .font(.headline)
                        .lineLimit(2)

                    Spacer()

                    Text("#\(issue.number)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 4) {
                    Text(issue.repositoryDisplayName)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(issue.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                let visibleLabels = Kanban.visibleLabels(issue.labels)
                if !visibleLabels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(visibleLabels) { label in
                                LabelBadge(label: label)
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct LabelBadge: View {
    let label: Label

    var body: some View {
        Text(label.name)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: label.color).opacity(0.2))
            .foregroundColor(Color(hex: label.color))
            .cornerRadius(4)
    }
}

// Helper extension to convert hex color strings to SwiftUI Color
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6: // RGB
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (128, 128, 128) // Default gray
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

// Wrapper to allow StateObject with late initialization
@MainActor
class IssuesListViewModelWrapper: ObservableObject {
    var viewModel: IssuesListViewModel? {
        didSet {
            if let viewModel = viewModel {
                // Forward changes from the nested ViewModel
                // Schedule the send on the next run loop to avoid publishing during view update
                viewModel.objectWillChange.sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.objectWillChange.send()
                    }
                }.store(in: &cancellables)
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
}

struct MultiSelectDetailView: View {
    let selectedIssues: Set<Issue>
    let onBatchClone: () -> Void
    let onBatchAssign: () -> Void
    let onBatchCopy: () -> Void
    let onBatchMove: () -> Void
    let onBatchClose: () -> Void
    let onBatchDelete: () -> Void

    private var openCount: Int { selectedIssues.filter { $0.state == .open }.count }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("\(selectedIssues.count) Issues Selected")
                .font(.title2)
                .fontWeight(.semibold)

            // Preview of selected issue titles
            VStack(alignment: .leading, spacing: 6) {
                let sorted = selectedIssues.sorted { $0.number < $1.number }
                ForEach(sorted.prefix(5)) { issue in
                    HStack(spacing: 8) {
                        Image(systemName: issue.state == .open ? "circle" : "checkmark.circle.fill")
                            .foregroundColor(issue.state == .open ? .green : .purple)
                            .font(.caption)
                        Text("#\(issue.number) \(issue.title)")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundColor(.primary)
                    }
                }
                if selectedIssues.count > 5 {
                    Text("and \(selectedIssues.count - 5) more…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: 320, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Batch action buttons
            VStack(spacing: 10) {
                Button {
                    onBatchClone()
                } label: {
                    SwiftUI.Label("Clone \(selectedIssues.count) Issues", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onBatchAssign()
                } label: {
                    SwiftUI.Label("Assign \(selectedIssues.count) Issues", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onBatchCopy()
                } label: {
                    SwiftUI.Label("Copy \(selectedIssues.count) Issues to Repository…", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onBatchMove()
                } label: {
                    SwiftUI.Label("Move \(selectedIssues.count) Issues to Repository…", systemImage: "arrow.right.square")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if openCount > 0 {
                    Button {
                        onBatchClose()
                    } label: {
                        SwiftUI.Label("Close \(openCount) Open Issue\(openCount == 1 ? "" : "s")", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button(role: .destructive) {
                    onBatchDelete()
                } label: {
                    SwiftUI.Label("Delete \(selectedIssues.count) Issues", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

#Preview {
    ContentView()
        .environmentObject(OAuth2Manager())
}
