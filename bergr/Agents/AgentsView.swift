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
    #if os(macOS)
    private var macSelection: Binding<AgentRef?>?
    private var listSelection: Binding<String?> {
        Binding(get: {
            macSelection?.wrappedValue.map { "\($0.host.uuidString)|\($0.address)" }
        }, set: { value in
            guard let value, let bar = value.firstIndex(of: "|"),
                  let host = UUID(uuidString: String(value[..<bar])) else {
                macSelection?.wrappedValue = nil
                return
            }
            macSelection?.wrappedValue = AgentRef(host: host, address: String(value[value.index(after: bar)...]))
        })
    }

    init(sessions: SessionStore, selection: Binding<AgentRef?>,
         open: @escaping (_ host: Host.ID, _ address: String) -> Void) {
        self.sessions = sessions
        self.macSelection = selection
        self.open = open
    }
    #else
    private var listSelection: Binding<String?> { $picked }
    #endif
    /// "machine" or "attention"; empty is the device's default (attention on a phone).
    @AppStorage("agents.grouping") private var groupingSetting = ""
    @State private var showAllIdle = false
    @State private var showOlder = false
    private var byAttention: Bool {
        groupingSetting.isEmpty ? DeviceName.isPhone : groupingSetting == "attention"
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var searchModel = TranscriptSearchModel()
    @State private var digest = AwayDigestModel()

    init(sessions: SessionStore, openBeside: ((_ host: Host.ID, _ address: String) -> Void)? = nil,
         open: @escaping (_ host: Host.ID, _ address: String) -> Void) {
        self.sessions = sessions
        self.openBeside = openBeside
        self.open = open
    }

    var body: some View {
        // Worked out once per body, and read by the sections, the animation and the attention lists.
        let lists = machineLists
        List(selection: listSelection) {
            if !searchText.isEmpty {
                SearchResultsSections(model: searchModel, sessions: sessions, open: open)
            } else {
            if !digest.entries.isEmpty {
                Section { DigestCard(model: digest, open: open) }
            }
            if byAttention { attentionSections(lists) } else { machineSections(lists) }
            }
        }
        .searchable(text: $searchText, prompt: "Search conversations")
        .onSubmit(of: .search) {
            searchModel.search(searchText, machines: hosts.hosts.map { ($0, sessions.session(for: $0)) })
        }
        .onChange(of: searchText) { if searchText.isEmpty { searchModel.clear() } }
        .modifier(SearchResultsSections.InfoAlert(hit: $searchModel.info))
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { digest.appDidLeave() }
            if phase == .active {
                digest.appDidReturn {
                    machineLists.flatMap { list in
                        list.ordered.map { t in
                            AwayDigestModel.Candidate(
                                host: list.host,
                                machine: t.address.contains("/") ? String(t.address.prefix { $0 != "/" }) : list.host.name,
                                terminal: t, lines: list.session.digestLines(address: t.address))
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    Picker("Group by", selection: Binding(
                        get: { byAttention ? "attention" : "machine" }, set: { groupingSetting = $0 })) {
                        Label("Attention", systemImage: "hand.raised").tag("attention")
                        Label("Machine", systemImage: "server.rack").tag("machine")
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("Agents").font(.headline)
                        #if os(iOS)
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        #endif
                    }
                    .foregroundStyle(.primary)
                }
                .accessibilityLabel("Agents, grouped by \(byAttention ? "attention" : "machine")")
            }
        }
        #endif
        .modifier(AgentsListBehavior(view: self, orderKey: lists.flatMap { $0.ordered.map(\.address) }))
    }

    /// Every machine's terminals, live and in the agents list's order, split into this core's
    /// own and the linked machines' (`laptop/t3`). Worked out once per body.
    private var machineLists: [MachineLists] {
        hosts.hosts.map { host in
            let session = sessions.session(for: host)
            let live = session.terminals.filter(\.isLive)
            let ordered = AgentsOrdering.ordered(live)
            return MachineLists(
                host: host, session: session, ordered: ordered,
                own: ordered.filter { !$0.address.contains("/") },
                linked: linkedGroups(ordered, host: host, session: session),
                liveOwn: live.filter { !$0.address.contains("/") },
                liveLinked: linkedGroups(live, host: host, session: session))
        }
    }

    @ViewBuilder
    private func machineSections(_ lists: [MachineLists]) -> some View {
            ForEach(lists) { list in
                let host = list.host
                let session = list.session
                let terminals = list.own
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
                    // Linked machines go in the same section, under a heading row each: as section
                    // headers they pinned to the top and piled up over the list when scrolling.
                    ForEach(list.linked, id: \.name) { group in
                        LinkedMachineHeader(name: group.name, via: host.name, state: group.state,
                                            count: group.terminals.count)
                            .padding(.top, 10)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                        ForEach(group.terminals) { terminal in row(terminal, host: host, session: session) }
                    }
                } header: {
                    MachineHeader(host: host, session: session, count: terminals.count)
                }
            }
    }

    fileprivate func applyBehavior<V: View>(_ list: V, orderKey: [String]) -> some View {
        list
        #if os(macOS)
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 40)
        #else
        .listStyle(.plain)
        #endif
        // Rows glide to their new place when an agent's state re-sorts them; Reduce Motion fades.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35), value: orderKey)
        .sensoryFeedback(.selection, trigger: picked) { _, new in new != nil }
        // Pull down to reconnect every machine.
        .refreshable {
            for host in hosts.hosts {
                let session = sessions.session(for: host)
                if case .connected = session.state { continue }
                session.retry(keys: keys)
            }
        }
        #if os(iOS)
        .onChange(of: picked) { _, value in
            guard let value, let bar = value.firstIndex(of: "|"),
                  let host = UUID(uuidString: String(value[..<bar])) else { return }
            open(host, String(value[value.index(after: bar)...]))
        }
        // Back on the list: nothing stays picked, so the same row opens again.
        .onAppear { picked = nil }
        #endif
        .navigationTitle("Agents")
        .overlay {
            if hosts.hosts.isEmpty {
                ContentUnavailableView {
                    Label("No machines", systemImage: "server.rack")
                } description: {
                    Text("Add a machine that runs herdr to see its agents, or try Bergr first with a built-in demo machine.")
                } actions: {
                    // No server needed: a simulated machine with agents to chat with and answer.
                    Button("Try the Demo") { _ = hosts.addDemo() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { connectAll() }
        .onChange(of: hosts.hosts) { connectAll() }
    }

    // MARK: Attention

    struct Entry: Identifiable {
        let host: Host
        let session: HostSession
        let terminal: Terminal
        let machine: String
        var id: String { "\(host.id.uuidString)|\(terminal.address)" }
    }

    /// Every live terminal on every machine once, with the machine it runs on.
    private func attentionEntries(_ lists: [MachineLists]) -> [Entry] {
        lists.flatMap { list -> [Entry] in
            let own = list.liveOwn.map { Entry(host: list.host, session: list.session, terminal: $0, machine: list.host.name) }
            let linked = list.liveLinked.flatMap { group in
                group.terminals.map { Entry(host: list.host, session: list.session, terminal: $0, machine: group.name) }
            }
            return own + linked
        }
    }

    @ViewBuilder
    private func attentionSections(_ lists: [MachineLists]) -> some View {
        let all = attentionEntries(lists)
        let stamp: (Entry) -> UInt64 = { $0.terminal.statusMs ?? $0.terminal.createdMs }
        let needs = all.filter { [.needsYou, .error].contains($0.terminal.agentState) }.sorted { stamp($0) < stamp($1) }
        let now = Date.now
        // The setting is read once for the whole list, not per terminal.
        let hideAfter = QuietAgents.seconds
        let quiet = all.filter { QuietAgents.isQuiet($0.terminal, now: now, after: hideAfter) }
            .sorted { stamp($0) > stamp($1) }
        let recent = all.filter { !QuietAgents.isQuiet($0.terminal, now: now, after: hideAfter) }
        let finished = recent.filter { $0.terminal.agentState == .done }.sorted { stamp($0) > stamp($1) }
        let working = all.filter { $0.terminal.agentState == .working }.sorted { stamp($0) < stamp($1) }
        let idle = recent.filter { $0.terminal.agentState == .idle || $0.terminal.agentState == nil }
            .sorted { ($0.terminal.isAgent ? 0 : 1, stamp($1)) < ($1.terminal.isAgent ? 0 : 1, stamp($0)) }
        let shownIdle = showAllIdle ? idle : Array(idle.prefix(10))
        attentionSection("Needs you", needs, counted: true)
        attentionSection("Finished", finished, counted: true)
        attentionSection("Working", working, counted: false)
        if !idle.isEmpty {
            Section {
                ForEach(shownIdle) { entryRow($0) }
                if idle.count > shownIdle.count {
                    Button("Show \(idle.count - shownIdle.count) more") { withAnimation { showAllIdle = true } }
                        .font(.footnote.weight(.semibold))
                        .selectionDisabled()
                }
            } header: { AttentionHeader(title: "Idle", count: nil) }
        }
        // Finished and idle agents untouched for longer than the setting: out of the way, not gone.
        if !quiet.isEmpty {
            Section {
                if showOlder {
                    ForEach(quiet) { entryRow($0) }
                }
                Button(showOlder ? "Hide older" : "Show \(quiet.count) older") {
                    withAnimation { showOlder.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .selectionDisabled()
            } header: { AttentionHeader(title: "Older", count: nil) }
        }
        let down = unreachable
        if !down.isEmpty {
            Section {
                Text("Can't reach " + down.joined(separator: ", ") + ".")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        if all.isEmpty, down.isEmpty, !hosts.hosts.isEmpty {
            Text("No agents running.").font(.footnote).foregroundStyle(.tertiary).selectionDisabled()
        }
    }

    /// Machines that can't be reached: Bergr's own and the linked ones.
    private var unreachable: [String] {
        hosts.hosts.flatMap { host -> [String] in
            let session = sessions.session(for: host)
            var names: [String] = []
            if case .failed = session.state { names.append(host.name) }
            let direct = Set(hosts.hosts.flatMap { [$0.name.lowercased(), $0.target.host.lowercased()] })
            names += session.machines.filter { $0.state == "unreachable" && !direct.contains($0.name.lowercased()) }
                .map(\.name)
            return names
        }
    }

    @ViewBuilder
    private func attentionSection(_ title: String, _ items: [Entry], counted: Bool) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { entryRow($0) }
            } header: { AttentionHeader(title: title, count: counted ? items.count : nil) }
        }
    }

    private func entryRow(_ e: Entry) -> some View {
        row(e.terminal, host: e.host, session: e.session, machine: e.machine)
    }

    @ViewBuilder
    private func row(_ terminal: Terminal, host: Host, session: HostSession, machine: String? = nil) -> some View {
        SubagentRow(terminal: terminal, session: session, machine: machine)
            .tag("\(host.id.uuidString)|\(terminal.address)")
            .contextMenu {
                Button("Open", systemImage: "arrow.forward.circle") { open(host.id, terminal.address) }
                if let openBeside {
                    Button("Open Beside", systemImage: "rectangle.split.2x1") {
                        openBeside(host.id, terminal.address)
                    }
                }
                Button("Copy Address", systemImage: "doc.on.doc") {
                    Pasteboard.copy(terminal.address)
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

/// One machine's live terminals, as the lists need them (see `AgentsView.machineLists`).
private struct MachineLists: Identifiable {
    let host: Host
    let session: HostSession
    /// All live terminals, in the agents list's order.
    let ordered: [Terminal]
    /// This core's own terminals and the linked machines' groups, in that order.
    let own: [Terminal]
    let linked: [AgentsView.LinkedGroup]
    /// The same as the session has them: the attention lists sort their own.
    let liveOwn: [Terminal]
    let liveLinked: [AgentsView.LinkedGroup]
    var id: Host.ID { host.id }
}

/// An agent's row. Its sub-agent count is read here, so a chat feed's changes redraw only this row
/// and not the whole list.
private struct SubagentRow: View {
    let terminal: Terminal
    let session: HostSession
    let machine: String?

    var body: some View {
        AgentRow(terminal: terminal, subagents: session.runningSubagents(address: terminal.address), machine: machine)
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

private struct AttentionHeader: View {
    let title: String
    let count: Int?
    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Spacer()
            if let count { Text("\(count)").font(.footnote).monospacedDigit().foregroundStyle(.secondary) }
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
    }
}

/// The list's behavior, the same whichever way it's grouped.
private struct AgentsListBehavior: ViewModifier {
    let view: AgentsView
    /// The addresses in list order: a change re-sorts the rows, which then glide.
    let orderKey: [String]
    func body(content: Content) -> some View { view.applyBehavior(content, orderKey: orderKey) }
}
