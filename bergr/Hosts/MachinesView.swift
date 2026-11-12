import HerdrKit
import SwiftUI

/// The saved machines: add, edit, delete, keys. The sidebar's root while there are none (with the
/// first-run empty state), and the "Manage Machines" sheet otherwise.
struct MachinesView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.dismiss) private var dismiss
    let sessions: SessionStore
    @Binding var selection: Host.ID?
    /// Shown as a sheet: picking a machine closes it, and there's a Done button.
    var inSheet = false
    @State private var editing: Host?
    @State private var showingKeys = false
    @State private var showingSettings = false
    @State private var setupHost: Host?

    private var duplicates: [UUID: Host] {
        SameMachine.duplicates(hosts.hosts.map { ($0, sessions.existing($0.id)?.coreName) })
    }

    var body: some View {
        List {
            if hosts.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No machines", systemImage: "server.rack")
                } description: {
                    Text(LocalCore.isMac
                        ? "Add a machine using this Mac's SSH config and ssh-agent, or select a Bergr key."
                        : keys.keys.isEmpty
                        ? "Create an SSH key first, add it to your machine, then add the machine here."
                        : "Add a machine that runs herdr-core.")
                } actions: {
                    if keys.keys.isEmpty && !LocalCore.isMac {
                        Button("Create Key") { showingKeys = true }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Add Machine") { editing = newHost() }.buttonStyle(.borderedProminent)
                    }
                    if LocalCore.isAvailable && !hosts.hasLocal {
                        Button("Add This Mac") { selection = hosts.addLocal().id }
                    }
                    Button("Try the Demo") { _ = hosts.addDemo() }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                ForEach(hosts.hosts) { host in
                    Button {
                        if host.isDemo || host.isLocal {
                            selection = host.id
                            if inSheet { dismiss() }
                        } else {
                            editing = host
                        }
                    } label: {
                        HStack {
                            MachineRow(host: host, session: sessions.existing(host.id), sameAs: duplicates[host.id])
                            if host.id == selection {
                                Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .contextMenu {
                        Button("Show Terminals", systemImage: "terminal") {
                            selection = host.id
                            if inSheet { dismiss() }
                        }
                        if !host.isDemo && !host.isLocal {
                            Button("Edit", systemImage: "pencil") { editing = host }
                        }
                        if !host.isDemo {
                            Button("Setup", systemImage: "checklist") {
                                let session = sessions.session(for: host)
                                if session.state == .idle { session.start(keys: keys) }
                                setupHost = host
                            }
                        }
                        Divider()
                        Button("Move Up", systemImage: "arrow.up") { withAnimation { hosts.move(host, by: -1) } }
                            .disabled(hosts.hosts.first == host)
                        Button("Move Down", systemImage: "arrow.down") { withAnimation { hosts.move(host, by: 1) } }
                            .disabled(hosts.hosts.last == host)
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            if let index = hosts.hosts.firstIndex(of: host) { hosts.delete(at: [index]) }
                        }
                    }
                }
                .onMove { hosts.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { hosts.delete(at: $0) }
                if !hosts.hosts.isEmpty {
                    Button {
                        editing = newHost()
                    } label: {
                        AccentLabel(title: "Add Machine", systemImage: "plus")
                    }
                }
            } footer: {
                if !hosts.hosts.isEmpty {
                    Text("Tap a machine to edit it. Swipe to delete it; this removes it from Bergr only.")
                }
            }
        }
        .bergrTint()
        .navigationTitle("Machines")
        .toolbar {
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .leadingAction) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            ToolbarItem(placement: .trailingAction) {
                Button("Keys", systemImage: "key") { showingKeys = true }
            }
            ToolbarItem(placement: .trailingAction) {
                Menu {
                    Button("Add Machine", systemImage: "server.rack") { editing = newHost() }
                    if LocalCore.isAvailable && !hosts.hasLocal {
                        Button("Add This Mac", systemImage: "desktopcomputer") { selection = hosts.addLocal().id }
                    }
                } label: {
                    Label("Add Machine", systemImage: "plus")
                } primaryAction: {
                    editing = newHost()
                }
            }
        }
        .sheet(item: $editing) { host in
            HostEditor(host: host)
        }
        .sheet(item: $setupHost) { host in
            MachineSetupView(session: sessions.session(for: host))
        }
        .sheet(isPresented: $showingKeys) {
            KeysSheet { showingKeys = false }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(addDemo: { showingSettings = false; addDemo() }, sessions: sessions) { showingSettings = false }
        }
    }

    private func addDemo() {
        selection = hosts.addDemo().id
        if inSheet { dismiss() }
    }

    private func newHost() -> Host {
        Host.new(key: keys.keys.last?.id)
    }
}

extension Host {
    /// An empty machine for the editor, with the newest key preselected.
    static func new(key: UUID?) -> Host {
        Host(name: "", target: SSHTarget(host: "", username: ""), keyID: key)
    }
}

struct KeysSheet: View {
    let done: () -> Void

    var body: some View {
        NavigationStack {
            KeysView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: done)
                    }
                }
        }
    }
}

struct SettingsSheet: View {
    let addDemo: () -> Void
    var sessions: SessionStore?
    let done: () -> Void

    var body: some View {
        NavigationStack {
            SettingsView(sessions: sessions, addDemo: addDemo)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", action: done)
                    }
                }
        }
    }
}

/// A machine: status dot, name, `user@address`, how many agents it has, and why a failed
/// connection failed (in full).
struct MachineRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let host: Host
    let session: HostSession?
    /// Another saved machine that reaches the same herdr-core; the agent list shows that one.
    var sameAs: Host? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            ConnectionIndicator(state: session?.state ?? .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(host.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if let sameAs {
                    Label("Same machine as \(sameAs.name); its agents show there", systemImage: "rectangle.on.rectangle")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let reason = failure {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let session {
                if session.needsYouCount > 0 {
                    NeedsYouBadge(count: session.needsYouCount)
                }
                let agents = session.terminals.filter { $0.agentState != nil }.count
                if agents > 0 {
                    Text(agents == 1 ? "1 agent" : "\(agents) agents")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    private var failure: String? {
        if case .failed(let reason, _) = session?.state { return reason }
        return nil
    }
}

/// The same dots as the Agents screen: green connected, yellow connecting, red failed, gray idle.
struct ConnectionIndicator: View {
    let state: HostSession.State

    var body: some View {
        Circle().fill(color).frame(width: 10, height: 10)
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch state {
        case .idle: .gray
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }

    private var label: String {
        switch state {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed(_, let retrying): retrying ? "Reconnecting" : "Can't connect"
        }
    }
}
