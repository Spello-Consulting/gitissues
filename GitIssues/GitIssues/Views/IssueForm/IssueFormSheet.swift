//
//  IssueFormSheet.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

struct IssueFormSheet: View {
    @StateObject var viewModel: IssueFormViewModel
    @Environment(\.dismiss) private var dismiss
    var onSuccess: ((Issue) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(viewModel.isCreateMode ? "New Issue" : "Edit Issue")
                        .font(.headline)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding()

                Divider()

                // Form content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Repository picker (create mode only)
                        if viewModel.isCreateMode {
                            RepositoryPickerSection(viewModel: viewModel)
                        }

                        // Title field
                        TitleSection(viewModel: viewModel)

                        // Body editor - calculate available height
                        BodySection(
                            viewModel: viewModel,
                            availableHeight: calculateBodyHeight(windowHeight: geometry.size.height)
                        )

                        // Initial comment (create mode only) - fixed height
                        if viewModel.isCreateMode {
                            InitialCommentSection(viewModel: viewModel)
                        }

                        // Labels section
                        LabelPickerSection(viewModel: viewModel)

                        // State picker (edit mode only)
                        if !viewModel.isCreateMode {
                            StatePickerSection(viewModel: viewModel)
                        }

                        // Validation errors
                        if !viewModel.validationErrors.isEmpty {
                            ValidationErrorsView(errors: viewModel.validationErrors)
                        }

                        // Error message
                        if let errorMessage = viewModel.errorMessage {
                            ErrorMessageView(message: errorMessage)
                        }
                    }
                    .padding()
                }

                Divider()

                // Footer
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button(viewModel.isCreateMode ? "Create Issue" : "Save Changes") {
                        Task {
                            do {
                                let issue = try await viewModel.submit()
                                onSuccess?(issue)
                                dismiss()
                            } catch {
                                // Error is already set in viewModel
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(viewModel.isSubmitting)
                }
                .padding()
            }
        }
        .task {
            await viewModel.loadRepositories()
            // Load labels for edit mode (repository is already known)
            if !viewModel.isCreateMode {
                await viewModel.loadLabels()
            }
        }
    }

    /// Calculate available height for the Description editor
    private func calculateBodyHeight(windowHeight: CGFloat) -> CGFloat {
        // Base calculation: window height minus header, footer, padding, other sections
        var heightToSubtract: CGFloat = 140 // Header + footer + padding

        if viewModel.isCreateMode {
            heightToSubtract += 100 // Repository picker
            heightToSubtract += 310 // Initial comment section (250 + spacing + label)
        }

        heightToSubtract += 70  // Title field
        heightToSubtract += 150 // Labels section (approximate)

        if !viewModel.isCreateMode {
            heightToSubtract += 80  // State picker (edit mode only)
        }
        
        // Tweak for issue 40
        if viewModel.isCreateMode {
            heightToSubtract -= 50
        }
        else {
            heightToSubtract -= 40
        }

        let availableHeight = windowHeight - heightToSubtract
        return max(250, availableHeight) // Minimum 250px
    }
}

// MARK: - Repository Picker Section
struct RepositoryPickerSection: View {
    @ObservedObject var viewModel: IssueFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
                Text("Repository")
                    .font(.headline)
                Text("*")
                    .foregroundColor(.red)
            }

            if viewModel.isLoadingRepositories {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading repositories...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                Picker("", selection: $viewModel.selectedRepositoryId) {
                    Text("Select a repository...")
                        .tag(nil as String?)

                    ForEach(viewModel.availableRepositories) { repo in
                        Text(repo.fullName)
                            .tag(repo.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: viewModel.selectedRepositoryId) { _, _ in
                    // Load labels when repository changes
                    Task {
                        await viewModel.loadLabels()
                    }
                }
            }
        }
    }
}

// MARK: - Title Section
struct TitleSection: View {
    @ObservedObject var viewModel: IssueFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "textformat")
                    .foregroundColor(.secondary)
                Text("Title")
                    .font(.headline)
                Text("*")
                    .foregroundColor(.red)
            }

            TextField("Enter issue title", text: $viewModel.title)
                .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Body Section
struct BodySection: View {
    @ObservedObject var viewModel: IssueFormViewModel
    let availableHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text")
                    .foregroundColor(.secondary)
                Text("Description")
                    .font(.headline)
                Text("(optional, markdown supported)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            MarkdownEditorView(text: $viewModel.body, placeholder: "Add a description...")
                .frame(height: availableHeight)
                .border(Color.secondary.opacity(0.2), width: 1)
                .cornerRadius(4)
        }
    }
}

// MARK: - Initial Comment Section
struct InitialCommentSection: View {
    @ObservedObject var viewModel: IssueFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bubble.left")
                    .foregroundColor(.secondary)
                Text("Initial Comment")
                    .font(.headline)
                Text("(optional, markdown supported)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            MarkdownEditorView(text: $viewModel.initialComment, placeholder: "Add an initial comment...")
                .frame(height: 250)
                .border(Color.secondary.opacity(0.2), width: 1)
                .cornerRadius(4)
        }
    }
}

// MARK: - Label Picker Section
struct LabelPickerSection: View {
    @ObservedObject var viewModel: IssueFormViewModel
    @State private var showingCreateLabel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "tag")
                    .foregroundColor(.secondary)
                Text("Labels")
                    .font(.headline)
                Text("(optional)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if viewModel.selectedRepositoryId != nil && !viewModel.isLoadingLabels {
                    Button {
                        showingCreateLabel = true
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showingCreateLabel, arrowEdge: .trailing) {
                        NewLabelPopover(isCreating: viewModel.isCreatingLabel, isPresented: $showingCreateLabel) { name, color in
                            await viewModel.createLabel(name: name, color: color)
                            return viewModel.createLabelError == nil
                        }
                    }
                }
            }

            if viewModel.isLoadingLabels {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading labels...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else if viewModel.availableLabels.isEmpty {
                Text("No labels available for this repository")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(viewModel.availableLabels) { label in
                        Button {
                            if viewModel.selectedLabelIds.contains(label.id) {
                                viewModel.selectedLabelIds.remove(label.id)
                            } else {
                                viewModel.selectedLabelIds.insert(label.id)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.selectedLabelIds.contains(label.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.caption)
                                    .foregroundColor(viewModel.selectedLabelIds.contains(label.id) ? .accentColor : .secondary)

                                Text(label.name)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                viewModel.selectedLabelIds.contains(label.id)
                                    ? Color(hex: label.color).opacity(0.3)
                                    : Color(hex: label.color).opacity(0.15)
                            )
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        Color(hex: label.color).opacity(0.5),
                                        lineWidth: viewModel.selectedLabelIds.contains(label.id) ? 1.5 : 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            if let error = viewModel.createLabelError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }
}

// MARK: - State Picker Section
struct StatePickerSection: View {
    @ObservedObject var viewModel: IssueFormViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "circle")
                    .foregroundColor(.secondary)
                Text("State")
                    .font(.headline)
            }

            HStack(spacing: 16) {
                // Open state button
                Button {
                    viewModel.selectedState = .open
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.selectedState == .open ? "circle.fill" : "circle")
                            .foregroundColor(viewModel.selectedState == .open ? .accentColor : .secondary)
                        Text("Open")
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.selectedState == .open
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.selectedState == .open
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.3),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)

                // Closed state button
                Button {
                    viewModel.selectedState = .closed
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.selectedState == .closed ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(viewModel.selectedState == .closed ? .accentColor : .secondary)
                        Text("Closed")
                            .foregroundColor(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        viewModel.selectedState == .closed
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                viewModel.selectedState == .closed
                                    ? Color.accentColor
                                    : Color.secondary.opacity(0.3),
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Validation Errors View
struct ValidationErrorsView: View {
    let errors: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(errors, id: \.self) { error in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.callout)
                        .foregroundColor(.primary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Error Message View
struct ErrorMessageView: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.circle")
                .foregroundColor(.red)
            Text(message)
                .font(.callout)
                .foregroundColor(.primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }
}
