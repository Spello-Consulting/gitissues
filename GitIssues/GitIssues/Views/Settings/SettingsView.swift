//
//  SettingsView.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authManager: OAuth2Manager
    @StateObject private var appearanceService = AppearanceService.shared

    var body: some View {
        TabView {
            GeneralSettingsView(appearanceService: appearanceService, authManager: authManager)
                .tabItem {
                    SwiftUI.Label("General", systemImage: "gearshape")
                }

            KanbanSettingsView()
                .tabItem {
                    SwiftUI.Label("Kanban", systemImage: "rectangle.split.3x1")
                }

            LoggingSettingsView()
                .tabItem {
                    SwiftUI.Label("Logging", systemImage: "doc.text.magnifyingglass")
                }
        }
        // Tall enough for the General tab (the longest) without scrolling, including the optional
        // "Reduce permissions" block.
        .frame(width: 540, height: 740)
    }
}

struct GeneralSettingsView: View {
    @ObservedObject var appearanceService: AppearanceService
    @ObservedObject var authManager: OAuth2Manager

    @AppStorage(AppStateService.syncEnabledKey) private var syncEnabled = true
    @AppStorage(AppStateService.syncIntervalSecondsKey) private var syncIntervalSeconds = 30
    @AppStorage(AppStateService.allowReadOnlyRepoAccessKey) private var allowReadOnlyRepoAccess = false
    @AppStorage(AppStateService.showIssueActivityKey) private var showIssueActivity = true

    private static let intervalOptions = [10, 15, 30, 60, 120, 300]

    private static func intervalLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds) seconds" }
        let minutes = seconds / 60
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 16) {
                // Appearance Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance")
                        .font(.headline)
                    Picker("Display Mode", selection: $appearanceService.currentMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Choose how GitIssues should appear")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Background Sync Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Background Sync")
                        .font(.headline)

                    Toggle("Automatically sync issues with GitHub", isOn: $syncEnabled)

                    if syncEnabled {
                        Picker("Sync every", selection: $syncIntervalSeconds) {
                            ForEach(Self.intervalOptions, id: \.self) { interval in
                                Text(Self.intervalLabel(interval)).tag(interval)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 250)
                    }

                    Text("When enabled, issues are refreshed in the background at the chosen interval.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Issue Detail Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Issue Detail")
                        .font(.headline)

                    Toggle("Show GitHub activity log", isOn: $showIssueActivity)

                    Text("When enabled, label, assignment, open/close and rename events are listed in line with the comments in the issue detail panel.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // GitHub Access Section
                VStack(alignment: .leading, spacing: 6) {
                    Text("GitHub Access")
                        .font(.headline)

                    Toggle("Allow private repository access", isOn: $authManager.allowPrivateRepoAccess)
                        .onChange(of: authManager.allowPrivateRepoAccess) { _, newValue in
                            // If the user turns ON private access while signed in, we must re-auth to request the broader scope.
                            if authManager.isAuthenticated && newValue {
                                authManager.reauthorizeForScopeChange()
                            }
                        }

                    Text("When enabled, GitIssues will request access to your private repositories. You'll need to re-authenticate with GitHub.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if authManager.isAuthenticated && !authManager.allowPrivateRepoAccess {
                        Button("Reduce permissions (re-authenticate)") {
                            authManager.reauthorizeForScopeChange()
                        }
                        .padding(.top, 6)

                        Text("If you previously granted private repository access, use this to re-authorize GitIssues with reduced permissions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Toggle("Allow read-only repository access", isOn: $allowReadOnlyRepoAccess)
                        .padding(.top, 6)
                        .onChange(of: allowReadOnlyRepoAccess) { _, _ in
                            NotificationCenter.default.post(name: .allowReadOnlyRepoAccessChanged, object: nil)
                        }

                    Text("When disabled, issues from archived or read-only repositories are hidden. When enabled, they're shown but their operations (edit, close, assign, delete, kanban moves) remain disabled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Local issue cache (issue #109)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Local Cache")
                        .font(.headline)

                    Button("Clear Cache & Reload") {
                        IssueCacheStore.shared.clear()
                        NotificationCenter.default.post(name: .issueCacheCleared, object: nil)
                    }

                    Text("GitIssues keeps a copy of your issues on this Mac so the list appears instantly at launch, then updates it in the background. Clearing it deletes that copy and reloads everything from GitHub. Use this if the list ever looks out of date.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
        }
        .formStyle(.grouped)
    }
}

struct LoggingSettingsView: View {
    @AppStorage(AppLogger.logLevelKey) private var logLevelRaw = LogLevel.information.rawValue
    @AppStorage(AppLogger.maxFileSizeMBKey) private var maxFileSizeMB = AppLogger.defaultMaxFileSizeMB
    @AppStorage(AppLogger.maxFileCountKey) private var maxFileCount = AppLogger.defaultMaxFileCount
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            VStack(alignment: .leading, spacing: 20) {
                // Logging level
                VStack(alignment: .leading, spacing: 6) {
                    Text("Logging Level")
                        .font(.headline)

                    Picker("Log entries to record", selection: $logLevelRaw) {
                        ForEach(LogLevel.allCases) { level in
                            Text(level.displayName).tag(level.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 250)

                    Text("Records entries at the selected level and all more serious ones. “Debug” records everything; “Errors” records only errors.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                // Log files
                VStack(alignment: .leading, spacing: 6) {
                    Text("Log Files")
                        .font(.headline)

                    Text("Logs are stored in the app's container. When the current log reaches the maximum size it is archived and a new one started; the oldest files are deleted once the file limit is reached.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    limitRow("Maximum file size", unit: "MB", value: $maxFileSizeMB, range: AppLogger.maxFileSizeMBRange)
                        .padding(.top, 4)
                    limitRow("Maximum number of files", unit: nil, value: $maxFileCount, range: AppLogger.maxFileCountRange)

                    HStack {
                        Button("Reveal in Finder") {
                            AppLogger.shared.revealInFinder()
                        }

                        Button("Delete All Logs…", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding()
        }
        .formStyle(.grouped)
        .alert("Delete All Logs", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                AppLogger.shared.deleteAllLogs()
                AppLogger.shared.info("Log files deleted by user")
            }
        } message: {
            Text("This permanently deletes all GitIssues log files. This cannot be undone.")
        }
        .onChange(of: maxFileSizeMB) { _, newValue in
            maxFileSizeMB = min(max(newValue, AppLogger.maxFileSizeMBRange.lowerBound), AppLogger.maxFileSizeMBRange.upperBound)
        }
        .onChange(of: maxFileCount) { _, newValue in
            maxFileCount = min(max(newValue, AppLogger.maxFileCountRange.lowerBound), AppLogger.maxFileCountRange.upperBound)
            AppLogger.shared.applyRetention()
        }
    }

    /// A labelled numeric field with a stepper, constrained to `range`.
    private func limitRow(_ title: String, unit: String?, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 60)
            Stepper(title, value: value, in: range)
                .labelsHidden()
            if let unit {
                Text(unit).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: 360)
    }
}

#Preview {
    SettingsView()
}
