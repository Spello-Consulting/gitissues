//
//  KanbanBoardView.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI
import AppKit

/// The Kanban board shown in the left panel when Kanban View is active. Renders one equal-width
/// column per configured state, populated from the view model's already-filtered issue list.
/// Selection is shared with `ContentView`, so the right (detail / multi-op) panel is unchanged.
struct KanbanBoardView: View {
    @ObservedObject var viewModel: IssuesListViewModel
    @ObservedObject var settings: KanbanSettingsService
    @Binding var selectedIssues: Set<Issue>
    let actions: IssueActions

    @State private var selectionAnchor: Issue?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(settings.states.enumerated()), id: \.element.id) { index, state in
                KanbanColumnView(
                    state: state,
                    issues: issues(for: state),
                    viewModel: viewModel,
                    selectedIssues: $selectedIssues,
                    selectionAnchor: $selectionAnchor,
                    actions: actions
                )
                .frame(maxWidth: .infinity)

                if index < settings.states.count - 1 {
                    Divider()
                }
            }
        }
        .animation(.default, value: viewModel.filteredIssues)
        .overlay(alignment: .bottom) {
            if let message = viewModel.kanbanToastMessage {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.secondary.opacity(0.25)))
                    .padding(.bottom, 16)
                    .shadow(radius: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: viewModel.kanbanToastMessage)
    }

    /// Issues for a column: those whose placement resolves to `state`. Manually-ordered issues
    /// (with an order key) come first, sorted by key; unkeyed issues follow in filtered order.
    private func issues(for state: KanbanState) -> [Issue] {
        let inColumn = viewModel.filteredIssues.filter { settings.state(for: $0).id == state.id }
        let keyed = inColumn
            .filter { $0.kanbanOrderKey != nil }
            .sorted { ($0.kanbanOrderKey ?? "") < ($1.kanbanOrderKey ?? "") }
        let unkeyed = inColumn.filter { $0.kanbanOrderKey == nil }
        return keyed + unkeyed
    }
}

// MARK: - Column

struct KanbanColumnView: View {
    let state: KanbanState
    let issues: [Issue]
    @ObservedObject var viewModel: IssuesListViewModel
    @Binding var selectedIssues: Set<Issue>
    @Binding var selectionAnchor: Issue?
    let actions: IssueActions

    @State private var appendTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text(state.name)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text("\(issues.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Cards + drop zones
            ZStack {
                // Background "append to end" drop target for empty space.
                Color.clear
                    .contentShape(Rectangle())
                    .dropDestination(for: String.self) { items, _ in
                        handleDrop(ids: items, at: issues.count)
                        return true
                    } isTargeted: { appendTargeted = $0 }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                            KanbanGapDropZone { ids in handleDrop(ids: ids, at: index) }
                            KanbanCardView(
                                issue: issue,
                                isSelected: selectedIssues.contains(issue),
                                onTap: { handleTap(issue) },
                                onDoubleTap: {
                                    guard !issue.repository.isReadOnly else { return }
                                    selectedIssues = [issue]
                                    actions.edit(issue)
                                }
                            )
                            .draggableIf(!issue.repository.isReadOnly, issue.id)
                            .contextMenu {
                                issueContextMenu(for: issue, selection: selectedIssues, actions: actions)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                        }
                        // Trailing gap: insert after the last card.
                        KanbanGapDropZone { ids in handleDrop(ids: ids, at: issues.count) }
                            .frame(minHeight: 40)
                    }
                    .padding(.vertical, 4)
                }
            }
            .background(appendTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
        }
    }

    // MARK: - Selection

    private func handleTap(_ issue: Issue) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selectedIssues.contains(issue) {
                selectedIssues.remove(issue)
            } else {
                selectedIssues.insert(issue)
            }
            selectionAnchor = issue
        } else if flags.contains(.shift),
                  let anchor = selectionAnchor,
                  let a = issues.firstIndex(of: anchor),
                  let b = issues.firstIndex(of: issue) {
            let range = a <= b ? a...b : b...a
            selectedIssues.formUnion(range.map { issues[$0] })
        } else {
            selectedIssues = [issue]
            selectionAnchor = issue
        }
    }

    // MARK: - Drop

    private func handleDrop(ids: [String], at insertIndex: Int) {
        let dropped = ids.compactMap { id in viewModel.allIssues.first(where: { $0.id == id }) }
        guard let primary = dropped.first else { return }

        let toMove: [Issue]
        if selectedIssues.contains(primary) && selectedIssues.count > 1 {
            // Move the whole selection, in a stable order.
            toMove = selectedIssues.sorted { lhs, rhs in
                let lk = lhs.kanbanOrderKey ?? ""
                let rk = rhs.kanbanOrderKey ?? ""
                return lk == rk ? lhs.number < rhs.number : lk < rk
            }
        } else {
            toMove = [primary]
        }

        // No-op: a single card dropped adjacent to itself in its own column.
        if toMove.count == 1,
           KanbanSettingsService.shared.state(for: primary).id == state.id,
           let pIdx = issues.firstIndex(of: primary),
           insertIndex == pIdx || insertIndex == pIdx + 1 {
            return
        }

        // Neighbour keys, skipping any items being moved.
        let movingSet = Set(toMove)
        var aboveKey: String?
        var j = insertIndex - 1
        while j >= 0 {
            if !movingSet.contains(issues[j]) { aboveKey = issues[j].kanbanOrderKey; break }
            j -= 1
        }
        var belowKey: String?
        var k = insertIndex
        while k < issues.count {
            if !movingSet.contains(issues[k]) { belowKey = issues[k].kanbanOrderKey; break }
            k += 1
        }

        if toMove.count == 1 {
            let key = FractionalIndex.keyBetween(aboveKey, belowKey)
            Task { await viewModel.moveIssue(toMove[0], to: state, orderKey: key) }
        } else {
            let keys = FractionalIndex.keysBetween(aboveKey, belowKey, count: toMove.count)
            Task { await viewModel.moveIssues(toMove, to: state, orderKeys: keys) }
        }
    }
}

// MARK: - Gap drop zone

/// A thin drop target between two cards. Shows an insertion line when a drag hovers over it.
private struct KanbanGapDropZone: View {
    let onDrop: ([String]) -> Void
    @State private var targeted = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 8)
            .overlay {
                if targeted {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                }
            }
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                onDrop(items)
                return true
            } isTargeted: { targeted = $0 }
    }
}

// MARK: - Card

struct KanbanCardView: View {
    let issue: Issue
    let isSelected: Bool
    let onTap: () -> Void
    var onDoubleTap: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: issue.state == .open ? "circle" : "checkmark.circle.fill")
                    .foregroundColor(issue.state == .open ? .green : .purple)
                    .font(.caption)
                Text(issue.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("#\(issue.number)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(issue.repositoryDisplayName)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)

            let labels = Kanban.visibleLabels(issue.labels)
            if !labels.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(labels) { label in
                            LabelBadge(label: label)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        // The double-tap recogniser must come first so it takes precedence over the single tap.
        .onTapGesture(count: 2) { onDoubleTap() }
        .onTapGesture { onTap() }
    }
}

private extension View {
    /// Applies `.draggable` only when `condition` is true; read-only cards can't be dragged.
    @ViewBuilder
    func draggableIf<T: Transferable>(_ condition: Bool, _ payload: T) -> some View {
        if condition {
            self.draggable(payload)
        } else {
            self
        }
    }
}
