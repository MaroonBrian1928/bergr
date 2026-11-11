import SwiftUI

/// The Settings window (⌘,): the shared settings form (machines, keys, notifications, appearance).
struct MacSettings: View {
    let sessions: SessionStore

    var body: some View {
        TabView {
            NavigationStack { SettingsView(sessions: sessions) }
                .tabItem { Label("General", systemImage: "gearshape") }
            TerminalSettingsView()
                .padding()
                .tabItem { Label("Terminal", systemImage: "terminal") }
        }
        .frame(width: 560, height: 680)
    }
}
