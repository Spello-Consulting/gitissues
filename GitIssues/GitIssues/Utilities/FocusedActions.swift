//
//  FocusedActions.swift
//  GitIssues
//
//  Created by Claude Code
//

import SwiftUI

/// Focused-scene values that let menu commands (defined at the `App` level) act on whichever
/// window currently has focus. A window that doesn't publish a value leaves the command disabled.
private struct RefreshIssuesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    /// Starts a background refresh of the issues list. Published by the main window only.
    var refreshIssuesAction: (() -> Void)? {
        get { self[RefreshIssuesActionKey.self] }
        set { self[RefreshIssuesActionKey.self] = newValue }
    }
}
