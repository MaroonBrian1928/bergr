import HerdrKit
import SwiftUI

/// The main window. Sidebar: every agent on every machine (the shared `AgentsView`); detail: the
/// selected agent's chat. Other agents open in windows of their own (⌥⌘N, the menu-bar item).
struct MacRootView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    let sessions: SessionStore
    @Bindable var shell: MacShell

    var body: some View {
        NavigationSplitView {
            AgentsView(sessions: sessions) { host, address in shell.selection = AgentRef(host: host, address: address) }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Session", systemImage: "plus") { shell.showingNewSession = true }
                    }
                }
        } detail: {
            if let selected = shell.selection, let host = hosts.hosts.first(where: { $0.id == selected.host }) {
                ChatWindow(session: sessions.session(for: host), address: selected.address)
                    .id(selected)
            } else {
                ContentUnavailableView("No agent selected", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Pick an agent from the list."))
            }
        }
        .sheet(isPresented: $shell.showingNewSession) {
            NewSessionView(sessions: sessions) { host, address in
                shell.selection = AgentRef(host: host, address: address)
            }
            .frame(minWidth: 440, minHeight: 420)
        }
        .modifier(TrustPrompt(sessions: sessions))
        .focusedSceneValue(\.agentRef, shell.selection)
        .focusedSceneValue(\.showAgent, { shell.selection = $0 })
        .frame(minWidth: 760, minHeight: 480)
    }
}
