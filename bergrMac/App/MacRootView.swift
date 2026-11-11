import KeyStore
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
            VStack(spacing: 0) {
                AgentsView(sessions: sessions) { host, address in shell.selection = AgentRef(host: host, address: address) }
                Divider()
                Button("Add Machine…", systemImage: "plus") { shell.showingAddMachine = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button("Add Machine…", systemImage: "plus.rectangle") { shell.showingAddMachine = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("New Session", systemImage: "plus") { shell.showingNewSession = true }
                    }
                }
        } detail: {
            if let selected = shell.selection, let host = hosts.hosts.first(where: { $0.id == selected.host }) {
                ChatWindow(session: sessions.session(for: host), address: selected.address)
                    .id(selected)
            } else {
                ContentUnavailableView {
                    Label("No agent selected", systemImage: "bubble.left.and.text.bubble.right")
                } description: {
                    Text(hosts.hosts.isEmpty ? "Add a machine to connect to your agents." : "Pick an agent from the list.")
                } actions: {
                    Button("Add Machine…") { shell.showingAddMachine = true }
                }
            }
        }
        .sheet(isPresented: $shell.showingAddMachine) {
            HostEditor(host: Host.new(key: keys.keys.last?.id))
                .frame(width: 620, height: 640)
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
