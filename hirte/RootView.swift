import HerdrKit
import SwiftUI

/// Two columns when unfolded (terminals | terminal), a stack when folded. The machine is picked
/// from the sidebar's title, so it doesn't need a column of its own.
struct RootView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.scenePhase) private var scenePhase
    @State private var sessions = SessionStore()
    /// The machine shown in the sidebar, remembered across launches.
    @AppStorage("selectedHost") private var storedHost = ""
    @State private var selectedTerminal: String?
    @State private var columns = NavigationSplitViewVisibility.all

    private var selectedHost: Binding<Host.ID?> {
        Binding(
            get: {
                let ids = hosts.hosts.map(\.id)
                if let stored = UUID(uuidString: storedHost), ids.contains(stored) { return stored }
                return ids.first
            },
            set: { storedHost = $0?.uuidString ?? "" })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(sessions: sessions, selectedHost: selectedHost, selectedTerminal: $selectedTerminal)
                .modifier(PadSidebarWidth())
        } detail: {
            if let host = hosts.hosts.first(where: { $0.id == selectedHost.wrappedValue }),
               let address = selectedTerminal {
                TerminalScreenView(
                    session: sessions.session(for: host), address: address,
                    expanded: Binding(
                        get: { columns == .detailOnly },
                        set: { columns = $0 ? .detailOnly : .all }))
                    .id("\(host.id)/\(address)")
            } else {
                ContentUnavailableView(
                    "No terminal selected", systemImage: "terminal",
                    description: Text("Pick a terminal to see what it is doing."))
            }
        }
        .navigationSplitViewStyle(.balanced)
        #if DEBUG
        // `-hirte.demo YES` (videos, UI tests on a device with real machines): open the demo machine.
        .task {
            if UserDefaults.standard.bool(forKey: "hirte.demo") { storedHost = hosts.addDemo().id.uuidString }
        }
        #endif
        .onChange(of: selectedHost.wrappedValue) {
            selectedTerminal = nil
        }
        .onChange(of: hosts.hosts) { _, current in
            // Edited or deleted machines get a fresh session.
            for host in current where sessions.existing(host.id).map({ $0.host != host }) ?? false {
                sessions.remove(host.id)
            }
            for id in sessions.ids where !current.contains(where: { $0.id == id }) {
                sessions.remove(id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: sessions.pauseAll()
            case .active: sessions.resumePaused(keys: keys)
            default: break
            }
        }
    }
}

/// An iPad has room for the rows' titles in the list column; elsewhere (the unfolded Duo) the
/// column keeps the system's width.
private struct PadSidebarWidth: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
        } else {
            content
        }
    }
}
