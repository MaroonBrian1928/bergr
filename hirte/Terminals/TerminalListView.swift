import HerdrKit
import SwiftUI

/// A machine's terminals, live from events, in two views like herdr-app's sidebar: the agents
/// (what each is doing, with its status) or all terminals by space and tab.
struct TerminalListView: View {
    @Environment(KeyLibrary.self) private var keys
    let session: HostSession
    @Binding var selection: String?
    @AppStorage("terminals.view") private var mode = Mode.agents
    /// The rows each view had on screen, so switching back scrolls to where it was.
    @State private var visibleRows: [Mode: Set<String>] = [:]
    /// Set while a view is swapped in and scrolled back; rows coming and going then don't count.
    @State private var restoring: Mode?
    /// Hides a swapped-in list until it's scrolled back, so its top doesn't flash.
    @State private var concealed = false
    @State private var newTerminal: NewTerminalContext?
    @State private var confirmKill: Terminal?
    @State private var actionError: String?
    /// Collapsed sections as "hostID|sectionID" lines, remembered across launches.
    @AppStorage("terminals.collapsed") private var collapsed = ""

    enum Mode: String, CaseIterable, Identifiable {
        case agents, terminals
        var id: Self { self }
        var title: String { self == .agents ? "Agents" : "Terminals" }
    }

    var body: some View {
        content
            .navigationTitle(session.host.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New Terminal", systemImage: "plus") {
                        newTerminal = NewTerminalContext(folder: nil)
                    }
                    .disabled(session.state != .connected)
                }
            }
            .onAppear { session.start(keys: keys) }
            .sheet(item: $newTerminal) { context in
                NewTerminalView(session: session, context: context) { address in
                    selection = address
                }
            }
            .confirmationDialog(
                "Kill \(confirmKill?.nameInSpace ?? "")?", isPresented: .constant(confirmKill != nil),
                titleVisibility: .visible, presenting: confirmKill
            ) { terminal in
                Button("Kill", role: .destructive) { perform { try await session.kill(terminal.address) } }
                Button("Cancel", role: .cancel) { confirmKill = nil }
            } message: { terminal in
                Text("\(terminal.address) gets a hangup, then is terminated. Agents it started end with it.")
            }
            .alert("Could not do that", isPresented: .constant(actionError != nil)) {
                Button("OK") { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
            .alert(
                "Trust this machine?",
                isPresented: .constant(session.pendingHostKey != nil),
                presenting: session.pendingHostKey
            ) { _ in
                Button("Trust") { session.answerHostKey(trust: true) }
                Button("Cancel", role: .cancel) { session.answerHostKey(trust: false) }
            } message: { key in
                Text("First connection to \(key.host). Its host key fingerprint is\n\n\(key.fingerprint)\n\n"
                    + "Compare it with `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the machine.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if session.snapshot != nil {
            terminalList
        } else {
            switch session.state {
            case .failed(let message, let retrying):
                ConnectionProblem(message: message, retrying: retrying, session: session)
            default:
                VStack(spacing: 12) {
                    ProgressView()
                    if case .connecting(let step) = session.state {
                        Text(step).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Where a space works: its first terminal's folder, else the folder herdr-app recorded.
    private func spaceFolder(_ space: HerdrAppLayout.Space, _ section: TerminalSection) -> String {
        section.rows.first.map { $0.terminal.foreground?.cwd ?? $0.terminal.cwd } ?? space.folder
    }

    private func rowView(_ row: TerminalRow) -> some View {
        let terminal = row.terminal
        var add: ((Terminal) -> Void)?
        if canAddToHerdrApp(terminal) { add = { addToHerdrApp($0) } }
        let actions = TerminalActions(
            terminal: terminal, session: session, kill: { confirmKill = $0 }, remove: { remove($0) },
            addToHerdrApp: add, watch: { watch($0) })
        return row.tag(terminal.address).modifier(actions)
    }

    /// Live, on this machine, in no herdr-app space or pane, and not an agent's child
    /// (children follow their parent).
    private func canAddToHerdrApp(_ terminal: Terminal) -> Bool {
        guard terminal.isLive, !terminal.address.contains("/"), terminal.parent == nil,
              (terminal.labels[HerdrAppLayout.spaceLabel] ?? "").isEmpty
        else { return false }
        return !(session.layout?.spaces.contains { $0.tabs.contains { $0.terminals.contains(terminal.address) } } ?? false)
    }

    /// Labels it with a fresh space id: a running herdr-app opens a new space for it.
    private func addToHerdrApp(_ terminal: Terminal) {
        perform { try await session.label(terminal.address, [HerdrAppLayout.spaceLabel: HerdrAppLayout.newSpaceID()]) }
    }

    /// Opens it watching, this once.
    private func watch(_ terminal: Terminal) {
        session.watchNext = terminal.address
        selection = terminal.address
    }

    private func remove(_ terminal: Terminal) {
        if selection == terminal.address { selection = nil }
        perform { try await session.remove(terminal.address) }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        confirmKill = nil
        Task {
            do { try await action() } catch { actionError = error.localizedDescription }
        }
    }

    /// Whether a section is open; collapsing is remembered per machine. A section that starts
    /// collapsed is remembered when opened instead (its key gets an "open:" prefix).
    private func expanded(_ section: String, initially open: Bool = true) -> Binding<Bool> {
        let key = "\(session.host.id.uuidString)|\(open ? "" : "open:")\(section)"
        return Binding(
            get: { collapsed.split(separator: "\n").contains(Substring(key)) != open },
            set: { isOpen in
                var keys = collapsed.split(separator: "\n").map(String.init).filter { $0 != key }
                if isOpen != open { keys.append(key) }
                collapsed = keys.joined(separator: "\n")
            })
    }

    private var spaceSections: [TerminalSection] {
        TerminalGrouping.bySpace(session.terminals.filter(\.isLive), layout: session.layout)
    }

    /// Finished terminals, newest first, in one section of their own below the spaces.
    private var finished: [Terminal] {
        session.terminals.filter { !$0.isLive }.sorted { $0.createdMs > $1.createdMs }
    }

    /// The agents (terminals that report a status), by space, without nesting.
    private var agentSections: [TerminalSection] {
        TerminalGrouping.bySpace(session.terminals.filter(\.isAgent), layout: session.layout).compactMap { section in
            let rows = section.rows.filter { $0.terminal.isAgent }
                .map { TerminalSection.Row(terminal: $0.terminal, depth: 0, tab: nil) }
            return rows.isEmpty ? nil
                : TerminalSection(kind: section.kind, title: section.title, subtitle: section.subtitle, rows: rows)
        }
    }

    /// One list per view (`.id`), swapped without animation: agents are rows in both, and
    /// diffing one into the other slid them across while the rest faded over them. Switching back
    /// scrolls to the row that was at the top. (Keeping both lists alive would keep the position
    /// for free, but a hidden List stays in the accessibility tree; and `ScrollPosition` doesn't
    /// move a List.)
    private var terminalList: some View {
        ScrollViewReader { proxy in
            list(mode)
                .id(mode)
                .opacity(concealed ? 0 : 1)
                .onChange(of: mode) { _, mode in
                    restoring = mode
                    let seen = visibleRows[mode] ?? []
                    let top = rowOrder(mode).first { seen.contains($0) }
                    // At the top already: nothing to hide.
                    concealed = top != nil && top != rowOrder(mode).first
                    Task { @MainActor in
                        // The new list lays out its rows first.
                        try? await Task.sleep(for: .milliseconds(30))
                        if let top { proxy.scrollTo(top, anchor: .top) }
                        // Show it once the scroll has been drawn.
                        try? await Task.sleep(for: .milliseconds(20))
                        concealed = false
                        try? await Task.sleep(for: .milliseconds(180))
                        visibleRows[mode] = seen
                        if restoring == mode { restoring = nil }
                    }
                }
        }
            .safeAreaInset(edge: .top, spacing: 0) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    /// The rows of a view, top to bottom.
    private func rowOrder(_ shown: Mode) -> [String] {
        if shown == .agents { return agentSections.flatMap { $0.rows.map(\.terminal.address) } }
        let open = expanded("finished", initially: false).wrappedValue
        return spaceSections.flatMap { $0.rows.map(\.terminal.address) } + (open ? finished.map(\.address) : [])
    }

    private func tracking(_ address: String, in shown: Mode) -> RowVisibility {
        RowVisibility { isVisible in
            guard restoring == nil, mode == shown else { return }
            if isVisible { visibleRows[shown, default: []].insert(address) }
            else { visibleRows[shown]?.remove(address) }
        }
    }

    private func list(_ shown: Mode) -> some View {
        List(selection: $selection) {
            // Keep the last list visible while reconnecting, with a banner on top.
            if session.state != .connected {
                ConnectionBanner(state: session.state, session: session)
            }
            switch shown {
            case .agents:
                if agentSections.isEmpty {
                    ContentUnavailableView(
                        "No agents", systemImage: "sparkles",
                        description: Text("Agents that report their status to herdr show up here."))
                }
                ForEach(agentSections) { section in
                    Section(isExpanded: expanded("agents:\(section.id)")) {
                        ForEach(section.rows) { row in
                            rowView(TerminalRow(terminal: row.terminal, inSpace: true, style: .agent))
                                .modifier(tracking(row.terminal.address, in: shown))
                        }
                    } header: {
                        SpaceHeader(section: section)
                    }
                }
            case .terminals:
                if spaceSections.isEmpty {
                    ContentUnavailableView(
                        "No live terminals", systemImage: "terminal",
                        description: Text("Start one with `hc run --bg` on the machine."))
                }
                ForEach(spaceSections) { section in
                    Section(isExpanded: expanded(section.id)) {
                        ForEach(section.rows) { row in
                            rowView(TerminalRow(
                                terminal: row.terminal, depth: row.depth, tab: row.tab, inSpace: true, style: .terminal))
                                .modifier(tracking(row.terminal.address, in: shown))
                        }
                    } header: {
                        SpaceHeader(section: section)
                            .contextMenu {
                                if case .space(let id) = section.kind,
                                   let space = session.layout?.spaces.first(where: { $0.id == id })
                                {
                                    Button("New Terminal Here", systemImage: "plus") {
                                        newTerminal = NewTerminalContext(space: space, folder: spaceFolder(space, section))
                                    }
                                }
                            }
                    }
                }
                // Out of the way, but at hand to see how something ended or to remove it.
                if !finished.isEmpty {
                    Section(isExpanded: expanded("finished", initially: false)) {
                        ForEach(finished) { terminal in
                            rowView(TerminalRow(terminal: terminal, style: .terminal))
                                .modifier(tracking(terminal.address, in: shown))
                        }
                    } header: {
                        HStack {
                            Text("Finished")
                            Spacer()
                            Text("\(finished.count)").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !session.machines.isEmpty {
                Section("Machines added on \(session.coreName ?? "this core")") {
                    ForEach(session.machines) { machine in
                        LabeledContent(machine.name, value: machine.state)
                    }
                }
            }
            if !session.host.isDemo, let name = session.coreName, let version = session.coreVersion {
                Text("\(name) · herdr-core \(version)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.sidebar)
        .animation(.default, value: session.terminals.map(\.address))
    }
}

struct ConnectionProblem: View {
    @Environment(KeyLibrary.self) private var keys
    let message: String
    let retrying: Bool
    let session: HostSession

    var body: some View {
        ContentUnavailableView {
            Label(retrying ? "Reconnecting…" : "Could not connect", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(message)
        } actions: {
            Button(retrying ? "Retry Now" : "Retry") { session.retry(keys: keys) }
                .buttonStyle(.borderedProminent)
            if message.contains("host key") && message.contains("changed") {
                Button("Forget Stored Host Key", role: .destructive) { session.forgetHostKey() }
            }
        }
    }
}

struct ConnectionBanner: View {
    @Environment(KeyLibrary.self) private var keys
    let state: HostSession.State
    let session: HostSession

    var body: some View {
        HStack(spacing: 10) {
            switch state {
            case .connecting(let step):
                ProgressView().controlSize(.small)
                Text(step)
            case .failed(let message, let retrying):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(retrying ? "Reconnecting… \(message)" : message).lineLimit(2)
                Spacer()
                Button("Retry") { session.retry(keys: keys) }.buttonStyle(.bordered)
            default:
                Text("Not connected")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

struct TerminalRow: View {
    let terminal: Terminal
    var depth = 0
    var tab: String?
    /// Inside a space section the space name is already the header.
    var inSpace = false
    var style = Style.agent

    enum Style {
        /// What it is doing first, its status as a dot on the right.
        case agent
        /// Its name, program and folder; no status.
        case terminal
    }

    var body: some View {
        switch style {
        case .agent: agentRow
        case .terminal: terminalRow
        }
    }

    private var agentRow: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.headline(inSpace: inSpace)).lineLimit(1)
                if let detail = terminal.detail(inSpace: inSpace) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let progress = terminal.status?.progress, terminal.isLive, terminal.status?.state == "working" {
                    ProgressView(value: Double(min(max(progress, 0), 100)), total: 100)
                        .tint(StatusDot.color(for: "working"))
                        .scaleEffect(y: 0.6)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            StatusDot(state: terminal.isLive ? terminal.status?.state : "finished")
                .padding(.top, 6)
        }
        .accessibilityIdentifier(terminal.address)
    }

    private var terminalRow: some View {
        HStack(alignment: .top, spacing: 12) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * 18)
                    .padding(.top, 3)
                    .accessibilityLabel("Started by its parent")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(inSpace ? terminal.nameInSpace : terminal.displayName).lineLimit(1)
                        .foregroundStyle(terminal.isLive ? .primary : .secondary)
                    Spacer(minLength: 8)
                    if let tab {
                        Text(tab)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Tab \(tab)")
                    }
                }
                if let place = terminal.place {
                    Text(place).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .accessibilityIdentifier(terminal.address)
    }
}

/// Reports when a row comes on screen or goes off it.
struct RowVisibility: ViewModifier {
    let changed: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear { changed(true) }
            .onDisappear { changed(false) }
    }
}

/// Kill (live) or remove (finished) from a row's context menu or swipe. A live terminal's
/// menu shows its screen above, watched.
struct TerminalActions: ViewModifier {
    let terminal: Terminal
    let session: HostSession
    let kill: (Terminal) -> Void
    let remove: (Terminal) -> Void
    /// Set for live local terminals herdr-app doesn't show yet.
    var addToHerdrApp: ((Terminal) -> Void)?
    /// Opens a live terminal watching.
    var watch: ((Terminal) -> Void)?
    /// The row's width: the preview may not be wider than the column it opens in, or the
    /// system crops it (seen on the unfolded Duo).
    @State private var rowWidth: CGFloat = 0

    func body(content: Content) -> some View {
        Group {
            if terminal.isLive {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
                    .contextMenu { menu } preview: {
                        TerminalPeek(session: session, terminal: terminal, maxWidth: rowWidth)
                    }
            } else {
                content.contextMenu { menu }
            }
        }
        .swipeActions(edge: .trailing) {
            if terminal.isLive {
                Button("Kill", systemImage: "xmark.octagon") { kill(terminal) }.tint(.red)
            } else {
                Button("Remove", systemImage: "trash", role: .destructive) { remove(terminal) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if terminal.isLive, let watch {
            Button("Watch", systemImage: "eye") { watch(terminal) }
        }
        Button("Copy Address", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = terminal.address
        }
        if let addToHerdrApp {
            Button("Add to herdr-app", systemImage: "square.stack.badge.plus") { addToHerdrApp(terminal) }
        }
        if terminal.isLive {
            Button("Kill", systemImage: "xmark.octagon", role: .destructive) { kill(terminal) }
        } else {
            Button("Remove", systemImage: "trash", role: .destructive) { remove(terminal) }
        }
    }
}

/// A section's name and how many of its terminals need you. Spaces, by far the most common,
/// are just their name, like in herdr-app; only another machine's terminals get an icon.
struct SpaceHeader: View {
    let section: TerminalSection

    var body: some View {
        HStack(spacing: 6) {
            if case .machine = section.kind {
                Image(systemName: "server.rack")
                    .accessibilityLabel("Machine")
            }
            Text(section.title)
            Spacer()
            if section.needsYou > 0 {
                NeedsYouBadge(count: section.needsYou)
            }
        }
    }
}

extension Terminal {
    /// A live terminal whose program reports its status to herdr (an agent).
    var isAgent: Bool { isLive && status != nil }

    /// For the terminals view: the program and folder, or how it ended.
    var place: String? {
        if !isLive { return exitCode.map { "exited \($0)" } ?? reason ?? "finished" }
        if let foreground {
            return foreground.name == nameInSpace ? Self.abbreviate(foreground.cwd)
                : "\(foreground.name) · \(Self.abbreviate(foreground.cwd))"
        }
        return Self.abbreviate(cwd)
    }

    /// Its name inside a space: without herdr-app's "space / tab" label, which the header already says.
    var nameInSpace: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        if let foreground { return foreground.name }
        return address
    }

    /// The row's main line: what an agent is working on, else the terminal's name.
    func headline(inSpace: Bool) -> String {
        if isLive, let title = status?.title, !title.isEmpty { return title }
        return inSpace ? nameInSpace : displayName
    }

    /// The row's second line: who it is, then the details the headline leaves out.
    func detail(inSpace: Bool) -> String? {
        let name = inSpace ? nameInSpace : displayName
        let usesTitle = isLive && !(status?.title ?? "").isEmpty
        var parts: [String] = usesTitle ? [name] : []
        if let status, isLive {
            if let msg = status.msg, !msg.isEmpty { parts.append(msg) }
            if !usesTitle && parts.isEmpty { parts.append(status.state) }
        } else if let foreground {
            parts.append(foreground.name == name ? Self.abbreviate(foreground.cwd)
                : "\(foreground.name) · \(Self.abbreviate(foreground.cwd))")
        } else if !isLive {
            parts.append(exitCode.map { "exited \($0)" } ?? reason ?? "finished")
        } else {
            parts.append(Self.abbreviate(cwd))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What it is doing: the status message, else the foreground program and folder.
    var summary: String? {
        if let status, isLive {
            let message = [status.title, status.msg].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return message.isEmpty ? status.state : "\(status.state) · \(message)"
        }
        if let foreground {
            return "\(foreground.name) · \(Self.abbreviate(foreground.cwd))"
        }
        if !isLive {
            return exitCode.map { "exited \($0)" } ?? reason
        }
        return Self.abbreviate(cwd)
    }

    static func abbreviate(_ path: String) -> String {
        for prefix in ["/Users/", "/home/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") { return "~" + rest[slash...] }
            return "~"
        }
        return path
    }
}

/// herdr's status colors: working, blocked (needs you), done, idle.
struct StatusDot: View {
    let state: String?

    var body: some View {
        Circle()
            .fill(Self.color(for: state))
            .frame(width: 10, height: 10)
            .accessibilityLabel(state ?? "no status")
    }

    static func color(for state: String?) -> Color {
        switch state {
        case "working": .blue
        case "blocked": .needsYou
        case "error": .red
        case "done": .green
        case "idle": .gray
        case "finished": .gray.opacity(0.4)
        default: .secondary.opacity(0.5)
        }
    }
}

extension Color {
    /// Hirte's amber: a terminal waits for you.
    static let needsYou = Color(red: 0xf2 / 255, green: 0xb3 / 255, blue: 0x3d / 255)
}

/// How many terminals wait for you, in amber.
struct NeedsYouBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption.bold().monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Color.needsYou, in: Capsule())
            .foregroundStyle(Color(red: 0x30 / 255, green: 0x34 / 255, blue: 0x38 / 255))
            .accessibilityLabel("\(count) need you")
    }
}
