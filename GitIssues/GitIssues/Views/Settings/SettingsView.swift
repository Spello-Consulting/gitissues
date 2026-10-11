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
        .frame(width: 540, height: 560)
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
            VStack(alignment: .leading, spacing: 20) {
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
            }
            .padding()
        }
        .formStyle(.grouped)
    }
}

struct LoggingSettingsView: View {
    @AppStorage(AppLogger.logLevelKey) private var logLevelRaw = LogLevel.information.rawValue
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

                    Text("Logs are stored in the app's container and rotate automatically (up to 10 files, 20 MB each).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

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
    }
}

#Preview {
    SettingsView()
}
