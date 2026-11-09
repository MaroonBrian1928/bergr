import HerdrKit
import SwiftUI

/// Pure helpers for the all-machines list.
enum AgentsOrdering {
    /// Needs-you first (blocked, error), then working, done/unread, idle, then non-agents;
    /// newest status first within each.
    static func ordered(_ terminals: [Terminal]) -> [Terminal] {
        func rank(_ t: Terminal) -> Int {
            guard t.isAgent, let state = t.agentState else { return 4 }
            switch state {
            case .needsYou, .error: return 0
            case .working: return 1
            case .done: return 2
            case .idle: return 3
            }
        }
        func stamp(_ t: Terminal) -> UInt64 { t.statusMs ?? t.createdMs }
        return terminals.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            if ra != rb { return ra < rb }
            let (sa, sb) = (stamp(a.element), stamp(b.element))
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    static func title(_ t: Terminal) -> String {
        if t.isLive, let title = t.status?.title, !title.isEmpty { return title }
        return t.displayName
    }

    /// Current session info: status message or title, else the folder name.
    static func info(_ t: Terminal) -> String? {
        if let msg = t.status?.msg, !msg.isEmpty { return msg }
        if let title = t.title, !title.isEmpty, title != Self.title(t) { return title }
        let cwd = t.foreground?.cwd ?? t.cwd
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

/// Every agent terminal on every saved machine, grouped by machine.
struct AgentsView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    let sessions: SessionStore
    let open: (_ host: Host.ID, _ address: String) -> Void
    /// Opens it in a second pane next to the open one (wide screens only; nil hides the action).
    var openBeside: ((_ host: Host.ID, _ address: String) -> Void)?
    /// The row picked, "<host>|<address>". On a phone the split view moves to the terminal when
    /// the sidebar list's selection changes, so rows are selected, not buttons.
    @State private var picked: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sessions: SessionStore, openBeside: ((_ host: Host.ID, _ address: String) -> Void)? = nil,
         open: @escaping (_ host: Host.ID, _ address: String) -> Void) {
        self.sessions = sessions
        self.openBeside = openBeside
        self.open = open
    }

    var body: some View {
        List(selection: $picked) {
            ForEach(hosts.hosts) { host in
                let session = sessions.session(for: host)
                let all = AgentsOrdering.ordered(session.terminals.filter(\.isLive))
                // This core's own terminals; ones it reaches on its linked machines (`pwnpc/t3`)
                // get a section of their own below.
                let terminals = all.filter { !$0.address.contains("/") }
                Section {
                    // Why a machine can't connect, in full, with a way to try again; the other
                    // machines carry on.
                    if case .failed(let message, _) = session.state {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                            Spacer(minLength: 4)
                            Button("Retry") { session.retry(keys: keys) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        .selectionDisabled()
                    }
                    if case .connected = session.state, terminals.isEmpty {
                        Text("No agents running. Open this machine and tap New Terminal to start one.")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .selectionDisabled()
                    }
                    ForEach(terminals) { terminal in row(terminal, host: host, session: session) }
                } header: {
                    MachineHeader(host: host, session: session, count: terminals.count)
                }
                ForEach(linkedGroups(all, host: host, session: session), id: \.name) { group in
                    Section {
                        ForEach(group.terminals) { terminal in row(terminal, host: host, session: session) }
                    } header: {
                        LinkedMachineHeader(name: group.name, via: host.name, state: group.state,
                                            count: group.terminals.count)
                    }
                }
            }
        }
        .listStyle(.plain)
        // Rows glide to their new place when an agent's state re-sorts them; Reduce Motion fades.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35),
                   value: hosts.hosts.flatMap { host in
                       AgentsOrdering.ordered(sessions.session(for: host).terminals.filter(\.isLive)).map(\.address)
                   })
        .sensoryFeedback(.selection, trigger: picked) { _, new in new != nil }
        // Pull down to reconnect every machine.
        .refreshable {
            for host in hosts.hosts {
                let session = sessions.session(for: host)
                if case .connected = session.state { continue }
                session.retry(keys: keys)
            }
        }
        .onChange(of: picked) { _, value in
            guard let value, let bar = value.firstIndex(of: "|"),
                  let host = UUID(uuidString: String(value[..<bar])) else { return }
            open(host, String(value[value.index(after: bar)...]))
        }
        // Back on the list: nothing stays picked, so the same row opens again.
        .onAppear { picked = nil }
        .navigationTitle("Agents")
        .overlay {
            if hosts.hosts.isEmpty {
                ContentUnavailableView("No machines", systemImage: "server.rack",
                                       description: Text("Add a machine to see its agents."))
            }
        }
        .task { connectAll() }
        .onChange(of: hosts.hosts) { connectAll() }
    }

    @ViewBuilder
    private func row(_ terminal: Terminal, host: Host, session: HostSession) -> some View {
                        AgentRow(terminal: terminal, subagents: session.runningSubagents(address: terminal.address))
                            .tag("\(host.id.uuidString)|\(terminal.address)")
                            .contextMenu {
                                Button("Open", systemImage: "arrow.forward.circle") { open(host.id, terminal.address) }
                                if let openBeside {
                                    Button("Open Beside", systemImage: "rectangle.split.2x1") {
                                        openBeside(host.id, terminal.address)
                                    }
                                }
                                Button("Copy Address", systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = terminal.address
                                }
                            }
    }

    struct LinkedGroup { let name: String; let state: String?; let terminals: [Terminal] }

    /// The terminals of each machine this core is linked to, by machine. A machine that's also
    /// added to Bergr directly is left out here: its agents already show under it.
    private func linkedGroups(_ all: [Terminal], host: Host, session: HostSession) -> [LinkedGroup] {
        let direct = Set(hosts.hosts.filter { $0.id != host.id }.flatMap { [$0.name.lowercased(), $0.target.host.lowercased()] })
        let byMachine = Dictionary(grouping: all.filter { $0.address.contains("/") }) {
            String($0.address.prefix { $0 != "/" })
        }
        return byMachine.keys.sorted().compactMap { name in
            let machine = session.machines.first { $0.name == name }
            let names = [name, machine?.host, machine?.target].compactMap { $0?.lowercased() }
            if names.contains(where: direct.contains) { return nil }
            return LinkedGroup(name: name, state: machine?.state, terminals: byMachine[name] ?? [])
        }
    }

    private func connectAll() {
        for host in hosts.hosts {
            let session = sessions.session(for: host)
            if !session.isActive { session.start(keys: keys) }
        }
    }
}

private struct MachineHeader: View {
    let host: Host
    let session: HostSession
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            // The machine's name leads; its state and count are quieter.
            Text(host.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            if let text = stateText { Text(text).font(.footnote).foregroundStyle(.secondary) }
            Spacer()
            Text("\(count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch session.state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .idle: .gray
        }
    }

    private var stateText: String? {
        switch session.state {
        case .connected: nil
        case .connecting: "Connecting…"
        case .failed(_, let retrying): retrying ? "Reconnecting…" : "Can't connect"
        case .idle: "Not connected"
        }
    }
}

/// A machine reached through another machine's herdr-core.
private struct LinkedMachineHeader: View {
    let name: String
    let via: String
    let state: String?
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(state == "unreachable" ? "unreachable · via \(via)" : "via \(via)")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch state {
        case "connected": .green
        case "connecting", "needs_login": .yellow
        case "unreachable": .red
        default: .gray
        }
    }
}
