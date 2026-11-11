import HerdrKit
import SwiftUI

/// Stub (chunk A refines): the main window. Sidebar: every agent on every machine (the shared
/// `AgentsView`); detail: the selected agent's chat.
struct MacRootView: View {
    @Environment(HostStore.self) private var hosts
    let sessions: SessionStore
    @State private var selected: AgentRef?

    var body: some View {
        NavigationSplitView {
            AgentsView(sessions: sessions) { host, address in selected = AgentRef(host: host, address: address) }
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            if let selected, let host = hosts.hosts.first(where: { $0.id == selected.host }) {
                ChatWindow(session: sessions.session(for: host), address: selected.address)
                    .id(selected)
            } else {
                ContentUnavailableView("No agent selected", systemImage: "bubble.left.and.text.bubble.right",
                                       description: Text("Pick an agent from the list."))
            }
        }
        .modifier(TrustPrompt(sessions: sessions))
        .frame(minWidth: 760, minHeight: 480)
    }
}
