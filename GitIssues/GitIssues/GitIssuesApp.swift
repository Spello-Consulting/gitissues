//
//  GitIssuesApp.swift
//  GitIssues
//
//  Created by Nick Elsey on 21/1/2026.
//

import SwiftUI

@main
struct GitIssuesApp: App {
    @StateObject private var authManager = OAuth2Manager()

    init() {
        // Initialize appearance service to apply saved theme
        _ = AppearanceService.shared

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLogger.shared.info("GitIssues launched (version \(version), build \(build))")
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            MainAppView(authManager: authManager)
        }
        .commands {
            // Keep the New Item command empty since we don't need File > New
            CommandGroup(replacing: .newItem) { }

            // Add custom commands
            MainWindowCommands()
            ViewCommands()
        }
        .defaultPosition(.center)
        .defaultSize(width: 1200, height: 800)

        // Settings window
        Settings {
            SettingsView()
                .environmentObject(authManager)
        }

        // Issue Form Window
        WindowGroup(id: WindowIdentifier.issueForm.rawValue, for: IssueFormWindowData.self) { $windowData in
            if let data = windowData {
                IssueFormWindow(windowData: data)
                    .environmentObject(authManager)
            }
        }

        // Comment Form Window
        WindowGroup(id: WindowIdentifier.commentForm.rawValue, for: CommentFormWindowData.self) { $windowData in
            if let data = windowData {
                CommentFormWindow(windowData: data)
                    .environmentObject(authManager)
            }
        }
    }

}

// MARK: - Main App View
struct MainAppView: View {
    @ObservedObject var authManager: OAuth2Manager

    var body: some View {
        Group {
            if authManager.isAuthenticated {
                ContentView()
            } else {
                LoginView(authManager: authManager)
            }
        }
        .environmentObject(authManager)
    }
}

// MARK: - View Commands
/// Adds a "View" menu to switch the left panel between the normal list and the Kanban board.
/// Backed by `@AppStorage("kanbanViewEnabled")`, which `ContentView` also reads.
struct ViewCommands: Commands {
    @AppStorage("kanbanViewEnabled") private var kanbanViewEnabled = false
    /// Published by the main window; `nil` (command disabled) when another window has focus or a
    /// refresh is already running.
    @FocusedValue(\.refreshIssuesAction) private var refreshIssues

    var body: some Commands {
        CommandMenu("View") {
            Button("Refresh Issues") {
                refreshIssues?()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(refreshIssues == nil)

            Divider()

            // Two toggles acting as a radio group so each shows a checkmark when active.
            Toggle(isOn: Binding(
                get: { !kanbanViewEnabled },
                set: { if $0 { kanbanViewEnabled = false } }
            )) {
                Text("Normal View")
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])

            Toggle(isOn: Binding(
                get: { kanbanViewEnabled },
                set: { if $0 { kanbanViewEnabled = true } }
            )) {
                Text("Kanban View")
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Window Commands
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowList) {
            Button("GitIssues") {
                openWindow(id: "main")
            }
            .keyboardShortcut("0", modifiers: [.command])
        }
    }
}
