import HerdrKit
import SwiftUI
import UserNotifications

/// The Mac app. Stub shell (chunk A: per-agent windows, menu bar item, commands, settings scene).
/// The session store lives here so every window (and the menu bar) shares it.
@main
struct BergrMacApp: App {
    @State private var hosts = HostStore()
    @State private var keys = KeyLibrary()
    @State private var sessions = SessionStore()
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup("Bergr", id: "main") {
            MacRootView(sessions: sessions)
                .environment(hosts)
                .environment(keys)
                .onChange(of: appearance, initial: true) { _, appearance in appearance.apply() }
                .onOpenURL { url in
                    if let target = AgentLink.target(of: url) { NotificationRouter.shared.pending = target }
                }
        }
    }
}
