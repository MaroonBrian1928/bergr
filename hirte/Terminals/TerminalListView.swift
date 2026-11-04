import HerdrKit
import SwiftUI

/// A machine's terminals, grouped by what they need from you. Updates live from events.
struct TerminalListView: View {
    @Environment(KeyLibrary.self) private var keys
    let session: HostSession
    @Binding var selection: String?
    @State private var showFinished = false
    @AppStorage("terminals.grouping") private var grouping = Grouping.spaces
    @State private var newTerminal: NewTerminalContext?
    @State private var confirmKill: Terminal?
    @State private var actionError: String?
    /// Collapsed sections as "hostID|sectionID" lines, remembered across launches.
    @AppStorage("terminals.collapsed") private var collapsed = ""

    enum Grouping: String, CaseIterable, Identifiable {
        case spaces, status
        var id: Self { self }
        var title: String { self == .spaces ? "Spaces" : "Status" }
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
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Group by", selection: $grouping) {
                            ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                        }
                        Toggle("Show Finished", isOn: $showFinished)
                    } label: {
                        Label("View Options", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .disabled(session.snapshot == nil)
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
            terminal: terminal, kill: { confirmKill = $0 }, remove: { remove($0) }, addToHerdrApp: add)
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

    /// Whether a section is open; collapsing is remembered per machine.
    private func expanded(_ section: String) -> Binding<Bool> {
        let key = "\(session.host.id.uuidString)|\(section)"
        return Binding(
            get: { !collapsed.split(separator: "\n").contains(Substring(key)) },
            set: { open in
                var keys = collapsed.split(separator: "\n").map(String.init).filter { $0 != key }
                if !open { keys.append(key) }
                collapsed = keys.joined(separator: "\n")
            })
    }

    private var spaceSections: [TerminalSection] {
        let shown = session.terminals.filter { showFinished || $0.isLive }
        return TerminalGrouping.bySpace(shown, layout: session.layout)
    }

    private var terminalList: some View {
        let groups = TerminalGroup.group(session.terminals, showFinished: showFinished)
        return List(selection: $selection) {
            // Keep the last list visible while reconnecting, with a banner on top.
            if session.state != .connected {
                ConnectionBanner(state: session.state, session: session)
            }
            if session.terminals.filter({ showFinished || $0.isLive }).isEmpty {
                ContentUnavailableView(
                    "No live terminals", systemImage: "terminal",
                    description: Text("Start one with `hc run --bg` on the machine."))
            }
            switch grouping {
            case .spaces:
                ForEach(spaceSections) { section in
                    Section(isExpanded: expanded(section.id)) {
                        ForEach(section.rows) { row in
                            rowView(TerminalRow(terminal: row.terminal, depth: row.depth, tab: row.tab, inSpace: true))
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
            case .status:
                ForEach(groups) { group in
                    Section(group.title, isExpanded: expanded("status:\(group.title)")) {
                        ForEach(group.terminals) { terminal in
                            rowView(TerminalRow(terminal: terminal))
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

/// Sections in the order a person cares about them.
struct TerminalGroup: Identifiable {
    let title: String
    let terminals: [Terminal]
    var id: String { title }

    static func group(_ terminals: [Terminal], showFinished: Bool) -> [TerminalGroup] {
        let live = terminals.filter(\.isLive)
        func with(_ states: Set<String>) -> [Terminal] {
            live.filter { states.contains($0.status?.state ?? "") }
        }
        let needsYou = with(["blocked", "error"])
        let working = with(["working"])
        let done = with(["done"])
        let known = Set((needsYou + working + done).map(\.address))
        let other = live.filter { !known.contains($0.address) }
        var groups = [
            TerminalGroup(title: "Needs you", terminals: needsYou),
            TerminalGroup(title: "Working", terminals: working),
            TerminalGroup(title: "Done", terminals: done),
            TerminalGroup(title: known.isEmpty ? "Terminals" : "Other", terminals: other),
        ]
        if showFinished {
            groups.append(TerminalGroup(title: "Finished", terminals: terminals.filter { !$0.isLive }))
        }
        return groups.filter { !$0.terminals.isEmpty }
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, CGFloat(depth - 1) * 18)
                    .padding(.top, 3)
                    .accessibilityLabel("Started by its parent")
            }
            StatusDot(state: terminal.isLive ? terminal.status?.state : "finished")
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(terminal.headline(inSpace: inSpace)).lineLimit(1)
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
        }
        .accessibilityIdentifier(terminal.address)
    }
}

/// Kill (live) or remove (finished) from a row's context menu or swipe.
struct TerminalActions: ViewModifier {
    let terminal: Terminal
    let kill: (Terminal) -> Void
    let remove: (Terminal) -> Void
    /// Set for live local terminals herdr-app doesn't show yet.
    var addToHerdrApp: ((Terminal) -> Void)?

    func body(content: Content) -> some View {
        content
            .contextMenu {
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
            .swipeActions(edge: .trailing) {
                if terminal.isLive {
                    Button("Kill", systemImage: "xmark.octagon") { kill(terminal) }.tint(.red)
                } else {
                    Button("Remove", systemImage: "trash", role: .destructive) { remove(terminal) }
                }
            }
    }
}

/// A space's name, folder, and how many of its terminals need you.
struct SpaceHeader: View {
    let section: TerminalSection

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(section.title)
            Spacer()
            if section.needsYou > 0 {
                NeedsYouBadge(count: section.needsYou)
            }
        }
    }

    private var icon: String {
        switch section.kind {
        case .space: "square.stack"
        case .machine: "server.rack"
        case .other: "terminal"
        }
    }
}

extension Terminal {
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
