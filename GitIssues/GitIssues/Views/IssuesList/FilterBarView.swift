//
//  FilterBarView.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

struct FilterBarView: View {
    @ObservedObject var viewModel: IssuesListViewModel
    /// Whether the Kanban board (rather than the issue list) is showing. Adds the "Kanban Dragged"
    /// toggle to the Sort menu.
    var isKanbanMode: Bool = false
    @State private var showRepositorySelector = false
    @State private var showLabelSelector = false

    /// A Sort menu row for `option`, checkmarked when it is the selected option.
    @ViewBuilder
    private func sortButton(_ option: SortOption) -> some View {
        Toggle(option.displayName, isOn: Binding(
            get: { viewModel.filterOptions.sortOption.id == option.id },
            set: { _ in viewModel.setSortOption(option) }
        ))
    }

    /// The Sort menu's label. On the Kanban board with dragged order on, both parts apply.
    private var sortLabel: String {
        let name = viewModel.filterOptions.sortOption.displayName
        return isKanbanMode && viewModel.filterOptions.kanbanDragged ? "Kanban Dragged + \(name)" : name
    }

    var body: some View {
        VStack(spacing: 12) {
            // State filter (Open/Closed/All)
            HStack(spacing: 8) {
                Text("State:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("", selection: Binding(
                    get: { viewModel.filterOptions.stateFilter },
                    set: { viewModel.setStateFilter($0) }
                )) {
                    ForEach(IssueStateFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)
                .labelsHidden()

                Spacer()
            }

            // Visibility and Involvement row
            HStack(spacing: 16) {
                // Visibility filter
                HStack(spacing: 8) {
                    Text("Visibility:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { viewModel.filterOptions.visibilityFilter },
                        set: { viewModel.setVisibilityFilter($0) }
                    )) {
                        ForEach(VisibilityFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .labelsHidden()
                }

                // Involvement filter
                HStack(spacing: 8) {
                    Text("Involvement:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: Binding(
                        get: { viewModel.filterOptions.involvementFilter },
                        set: { viewModel.setInvolvementFilter($0) }
                    )) {
                        ForEach(InvolvementFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(minWidth: 150)
                    .labelsHidden()
                }

                Spacer()
            }

            // Repository filter and Sort row
            HStack(spacing: 16) {
                // Repository filter (if multiple repos)
                if viewModel.availableRepositories.count > 1 {
                    HStack(spacing: 8) {
                        Text("Repositories:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            showRepositorySelector = true
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.filterOptions.selectedRepositories.isEmpty {
                                    Text("All (\(viewModel.availableRepositories.count))")
                                        .font(.caption)
                                } else {
                                    Text("\(viewModel.filterOptions.selectedRepositories.count) selected")
                                        .font(.caption)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        if !viewModel.filterOptions.selectedRepositories.isEmpty {
                            Button {
                                viewModel.clearRepositoryFilter()
                            } label: {
                                Text("Clear")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Label filter
                if !viewModel.availableLabels.isEmpty {
                    HStack(spacing: 8) {
                        Text("Labels:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button {
                            showLabelSelector = true
                        } label: {
                            HStack(spacing: 6) {
                                if viewModel.filterOptions.selectedLabels.isEmpty {
                                    Text("All (\(viewModel.availableLabels.count))")
                                        .font(.caption)
                                } else {
                                    Text("\(viewModel.filterOptions.selectedLabels.count) selected")
                                        .font(.caption)
                                }
                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.1))
                            .foregroundColor(.accentColor)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        if !viewModel.filterOptions.selectedLabels.isEmpty {
                            Button {
                                viewModel.clearLabelFilter()
                            } label: {
                                Text("Clear")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                // Sort picker
                HStack(spacing: 8) {
                    Text("Sort:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Menu {
                        if isKanbanMode {
                            Toggle("Kanban Dragged", isOn: Binding(
                                get: { viewModel.filterOptions.kanbanDragged },
                                set: { viewModel.setKanbanDragged($0) }
                            ))
                            Divider()
                        }
                        sortButton(.updatedDesc)
                        sortButton(.updatedAsc)
                        Divider()
                        sortButton(.createdDesc)
                        sortButton(.createdAsc)
                        Divider()
                        sortButton(.numberDesc)
                        sortButton(.numberAsc)
                    } label: {
                        HStack(spacing: 4) {
                            Text(sortLabel)
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showRepositorySelector) {
            RepositorySelectorSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showLabelSelector) {
            LabelSelectorSheet(viewModel: viewModel)
        }
    }
}

