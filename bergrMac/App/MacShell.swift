import AppKit
import HerdrKit
import Observation
import SwiftUI

/// App-scoped UI state the main window, the commands and the menu bar share.
@MainActor @Observable
final class MacShell {
    /// The agent the main window shows.
    var selection: AgentRef?
    /// ⌘N: the main window presents the New Session sheet.
    var showingNewSession = false
}

/// What the focused window offers the commands (scene values, so they work without a focused view).
extension FocusedValues {
    /// The agent the focused window shows.
    @Entry var agentRef: AgentRef?
    /// Shows another agent in the focused window (the main window); nil where windows are per agent.
    @Entry var showAgent: ((AgentRef) -> Void)?
    /// Stops the focused window's agent (Esc in its terminal).
    @Entry var interruptAgent: (() -> Void)?
}

/// Closing the last window keeps Bergr running (the menu-bar item stays); the Dock icon brings the
/// main window back.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    /// Opens the main window; set once the scenes exist.
    var reopen: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { reopen?() }
        return true
    }
}
