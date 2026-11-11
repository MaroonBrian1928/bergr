import HerdrKit
import SwiftUI

/// The Mac app: the main window (agents list and chat), one window per agent, the menu-bar item,
/// settings and commands. The session store lives here so every window and the menu bar share it.
@main
struct BergrMacApp: App {
    @NSApplicationDelegateAdaptor private var delegate: MacAppDelegate
    @State private var hosts = HostStore()
    @State private var keys = KeyLibrary()
    @State private var sessions: SessionStore
    @State private var shell = MacShell()

    init() {
        let sessions = SessionStore()
        _sessions = State(initialValue: sessions)
        // Started at launch, so a notification clicked to open the app is delivered.
        MacNotifications.shared.start(sessions: sessions)
    }

    var body: some Scene {
        // A single main window: opening it again focuses it.
        Window("Bergr", id: "main") {
            MacRootView(sessions: sessions, shell: shell)
                .environment(hosts)
                .environment(keys)
                .onOpenURL { url in
                    if let target = AgentLink.target(of: url) { NotificationRouter.shared.pending = target }
                }
        }
        .defaultSize(width: 1000, height: 700)
        .commands { MacCommands(sessions: sessions, hosts: hosts, shell: shell) }

        // One window per agent; opening an agent that has one focuses it, and the windows come
        // back after a relaunch.
        WindowGroup("Agent", for: AgentRef.self) { $ref in
            if let ref {
                AgentWindow(ref: ref, sessions: sessions)
                    .environment(hosts)
                    .environment(keys)
            }
        }
        .defaultSize(width: 560, height: 760)

        MenuBarExtra {
            MenuBarContent(sessions: sessions)
                .environment(hosts)
        } label: {
            MenuBarLabel(sessions: sessions, delegate: delegate)
                .environment(hosts)
                .environment(keys)
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettings(sessions: sessions)
                .environment(hosts)
                .environment(keys)
        }
    }
}
