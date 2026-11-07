import HerdrKit
import SwiftUI

/// The one sidebar: the selected machine's terminals, with the machine switcher in the title.
/// Without machines, the machines list with its first-run empty state.
struct SidebarView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    let sessions: SessionStore
    @Binding var selectedHost: Host.ID?
    @Binding var selectedTerminal: String?
    @State private var showingMachines = false
    @State private var showingSettings = false
    @State private var editing: Host?

    var body: some View {
        if let host = hosts.hosts.first(where: { $0.id == selectedHost }) {
            TerminalListView(session: sessions.session(for: host), selection: $selectedTerminal)
                .id(host.id)
                // iOS only shows a title menu (name + chevron) on an inline title.
                .navigationBarTitleDisplayMode(.inline)
                // Settings lives in the title menu too: a gear in the toolbar left too little room
                // for the machine's name in the narrow sidebar of the unfolded Duo.
                .toolbarTitleMenu { switcher(current: host) }
                .sheet(isPresented: $showingMachines) {
                    NavigationStack {
                        MachinesView(sessions: sessions, selection: $selectedHost, inSheet: true)
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsSheet(addDemo: { showingSettings = false; selectedHost = hosts.addDemo().id }, sessions: sessions) {
                        showingSettings = false
                    }
                }
                .sheet(item: $editing) { host in
                    HostEditor(host: host)
                }
        } else {
            MachinesView(sessions: sessions, selection: $selectedHost)
        }
    }

    /// Tapping the title: every machine (with what needs you there), adding and managing them,
    /// and the settings.
    @ViewBuilder
    private func switcher(current: Host) -> some View {
        Section {
            ForEach(hosts.hosts) { host in
                Button {
                    selectedHost = host.id
                } label: {
                    Label(host.name, systemImage: host.id == current.id ? "checkmark" : icon(for: host))
                    if let detail = detail(for: host) { Text(detail) }
                }
            }
        }
        Section {
            Button("Add Machine…", systemImage: "plus") {
                editing = Host.new(key: keys.keys.last?.id)
            }
            Button("Manage Machines…", systemImage: "server.rack") { showingMachines = true }
        }
        Section {
            Button("Settings…", systemImage: "gearshape") { showingSettings = true }
        }
    }

    private func icon(for host: Host) -> String {
        host.isDemo ? "play.rectangle" : "server.rack"
    }

    /// "2 need you", or the connection state when it's not simply connected.
    private func detail(for host: Host) -> String? {
        guard let session = sessions.existing(host.id) else { return host.subtitle }
        if session.needsYouCount > 0 { return "\(session.needsYouCount) need you" }
        switch session.state {
        case .connected: return host.subtitle
        case .connecting: return "Connecting…"
        case .failed(_, let retrying): return retrying ? "Reconnecting…" : "Can't connect"
        case .idle: return host.subtitle
        }
    }
}
