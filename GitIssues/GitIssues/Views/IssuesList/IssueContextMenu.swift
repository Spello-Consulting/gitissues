//
//  IssueContextMenu.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

/// Bag of issue-action closures supplied by `ContentView`, so the same context menu can be
/// reused by both the list rows and the Kanban board cards.
struct IssueActions {
    var edit: (Issue) -> Void
    var clone: (Issue) -> Void
    var assign: (Issue) -> Void
    var editLabels: (Issue) -> Void
    var copyToRepo: ([Issue]) -> Void
    var moveToRepo: ([Issue]) -> Void
    var close: (Issue) -> Void
    var reopen: (Issue) -> Void
    var delete: (Issue) -> Void
    var batchClone: (Set<Issue>) -> Void
    var batchAssign: (Set<Issue>) -> Void
    var batchClose: (Set<Issue>) -> Void
    var batchDelete: (Set<Issue>) -> Void
}

/// The shared right-click menu for an issue. Shows batch operations when the issue is part of a
/// multi-selection, otherwise single-issue operations — matching the original list behaviour.
@ViewBuilder
func issueContextMenu(for issue: Issue, selection: Set<Issue>, actions: IssueActions) -> some View {
    let isBatchTarget = selection.contains(issue) && selection.count > 1
    if isBatchTarget {
        // Read-only repos reject issue mutations, so disable batch actions when any selected
        // issue belongs to one.
        let anyReadOnly = selection.contains { $0.repository.isReadOnly }
        Text("\(selection.count) issues selected")
            .foregroundColor(.secondary)
        if anyReadOnly {
            Text("Some are read-only")
                .foregroundColor(.secondary)
        }
        Divider()
        Button {
            actions.batchClone(selection)
        } label: {
            SwiftUI.Label("Clone \(selection.count) Issues", systemImage: "doc.on.doc")
        }
        .disabled(anyReadOnly)
        Button {
            actions.batchAssign(selection)
        } label: {
            SwiftUI.Label("Assign \(selection.count) Issues", systemImage: "person.badge.plus")
        }
        .disabled(anyReadOnly)
        Button {
            actions.copyToRepo(Array(selection))
        } label: {
            SwiftUI.Label("Copy \(selection.count) Issues to Repository…", systemImage: "doc.on.doc")
        }
        .disabled(anyReadOnly)
        Button {
            actions.moveToRepo(Array(selection))
        } label: {
            SwiftUI.Label("Move \(selection.count) Issues to Repository…", systemImage: "arrow.right.square")
        }
        .disabled(anyReadOnly)
        let openCount = selection.filter { $0.state == .open }.count
        if openCount > 0 {
            Button {
                actions.batchClose(selection)
            } label: {
                SwiftUI.Label("Close \(openCount) Open Issue\(openCount == 1 ? "" : "s")", systemImage: "checkmark.circle")
            }
            .disabled(anyReadOnly)
        }
        Divider()
        Button(role: .destructive) {
            actions.batchDelete(selection)
        } label: {
            SwiftUI.Label("Delete \(selection.count) Issues", systemImage: "trash")
        }
        .disabled(anyReadOnly)
    } else {
        // Read-only repos reject issue mutations, so disable all operations for such issues.
        let isReadOnly = issue.repository.isReadOnly
        if isReadOnly {
            Text("Read-only repository")
                .foregroundColor(.secondary)
            Divider()
        }
        Button {
            actions.edit(issue)
        } label: {
            SwiftUI.Label("Edit Issue", systemImage: "pencil")
        }
        .disabled(isReadOnly)
        Button {
            actions.clone(issue)
        } label: {
            SwiftUI.Label("Clone Issue", systemImage: "doc.on.doc")
        }
        .disabled(isReadOnly)
        Button {
            actions.assign(issue)
        } label: {
            SwiftUI.Label("Assign Issue", systemImage: "person.badge.plus")
        }
        .disabled(isReadOnly)
        Button {
            actions.editLabels(issue)
        } label: {
            SwiftUI.Label("Labels…", systemImage: "tag")
        }
        .disabled(isReadOnly)
        Button {
            actions.copyToRepo([issue])
        } label: {
            SwiftUI.Label("Copy to Repository…", systemImage: "doc.on.doc")
        }
        .disabled(isReadOnly)
        Button {
            actions.moveToRepo([issue])
        } label: {
            SwiftUI.Label("Move to Repository…", systemImage: "arrow.right.square")
        }
        .disabled(isReadOnly)
        Divider()
        if issue.state == .open {
            Button {
                actions.close(issue)
            } label: {
                SwiftUI.Label("Close Issue", systemImage: "checkmark.circle")
            }
            .disabled(isReadOnly)
        } else {
            Button {
                actions.reopen(issue)
            } label: {
                SwiftUI.Label("Reopen Issue", systemImage: "arrow.counterclockwise.circle")
            }
            .disabled(isReadOnly)
        }
        Divider()
        Button(role: .destructive) {
            actions.delete(issue)
        } label: {
            SwiftUI.Label("Delete Issue", systemImage: "trash")
        }
        .disabled(isReadOnly)
    }
}
