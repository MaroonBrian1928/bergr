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
            AgentsView(sessions: sessions, selection: $shell.selection) { host, address in
                shell.selection = AgentRef(host: host, address: address)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 400)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Menu {
                            Button("Add Machine…") { shell.showingAddMachine = true }
                        } label: {
                            Image(systemName: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Add Machine")
                        .accessibilityLabel("Add Machine")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .background(.bar)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Session", systemImage: "square.and.pencil") { shell.showingNewSession = true }
                    .help("New Session (⌘N)")
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
            .frame(width: 540, height: 560)
        }
        .modifier(TrustPrompt(sessions: sessions))
        .focusedSceneValue(\.agentRef, shell.selection)
        .focusedSceneValue(\.showAgent, { shell.selection = $0 })
        .frame(minWidth: 760, minHeight: 480)
    }
}
