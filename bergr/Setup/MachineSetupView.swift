import SwiftUI

/// The Setup checklist for one machine: each item's status, and its action (Install, Update, Set
/// Up) or a command to copy when Bergr has no flow for it.
struct MachineSetupView: View {
    let session: HostSession
    @State private var setup: MachineSetup
    @State private var copied: String?
    @Environment(\.dismiss) private var dismiss

    init(session: HostSession) {
        self.session = session
        _setup = State(initialValue: MachineSetup(session: session))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { summary }
                Section {
                    row(.core, symbol: "server.rack") { EmptyView() }
                    row(.python, symbol: "curlybraces") { EmptyView() }
                } header: {
                    Text("Machine")
                }
                Section {
                    ForEach(AgentCLI.allCases) { agent in agentRow(agent) }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Install the agents you use. Bergr shows the ones it finds.")
                }
                Section {
                    row(.push, symbol: "bell.badge") { pushAction }
                    row(.statusLine, symbol: "gauge.with.dots.needle.33percent") { statusLineAction }
                } header: {
                    Text("Bergr")
                } footer: {
                    if let error = setup.actionError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("The push helper alerts you when an agent needs you. The status line shows context and plan usage in the chat.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set Up \(session.host.name)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Check Again", systemImage: "arrow.clockwise") { Task { await setup.check() } }
                        .disabled(session.state != .connected || setup.busy != nil)
                }
            }
            .task(id: session.state == .connected) {
                if session.state == .connected { await setup.check() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 640)
        #endif
    }

    // MARK: Summary

    /// Everything the checks found, in one line at the top: the answer to "is this machine ready?".
    private var states: [CheckState] {
        SetupItem.allCases.filter { $0 != .agents }.map { setup.states[$0] ?? .checking }
            + AgentCLI.allCases.map { setup.agents[$0] ?? .checking }
    }

    @ViewBuilder
    private var summary: some View {
        let open = states.filter { if case .ready = $0 { false } else if case .checking = $0 { false } else { true } }.count
        let checking = states.contains { if case .checking = $0 { true } else { false } }
        HStack(spacing: 12) {
            Group {
                if session.state != .connected {
                    Image(systemName: "bolt.horizontal.circle").foregroundStyle(.secondary)
                } else if checking {
                    ProgressView().controlSize(.small)
                } else if open == 0 {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Image(systemName: "wrench.and.screwdriver.fill").foregroundStyle(.orange)
                }
            }
            .font(.title2)
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.state != .connected ? "Not connected"
                     : checking ? "Checking \(session.host.name)…"
                     : open == 0 ? "\(session.host.name) is ready" : open == 1 ? "1 thing to set up" : "\(open) things to set up")
                    .font(.headline)
                Text(session.state != .connected ? "Connect to \(session.host.name) to check it."
                     : "What Bergr needs on this machine, and what it found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: Rows

    private func row<Action: View>(_ item: SetupItem, symbol: String, @ViewBuilder action: () -> Action) -> some View {
        let state = setup.states[item] ?? .checking
        return SetupRow(symbol: symbol, title: item.title, detail: Self.text(for: state)) {
            Self.icon(state)
            action()
        }
        .accessibilityIdentifier("setup-\(item.rawValue)")
    }

    private func agentRow(_ agent: AgentCLI) -> some View {
        let state = setup.agents[agent] ?? .checking
        let command = agent.installCommand(windows: setup.windows)
        let missing: Bool = if case .missing = state { true } else { false }
        return SetupRow(symbol: "sparkles", title: agent.title, detail: Self.text(for: state),
                        command: missing ? command : nil) {
            Self.icon(state)
            if missing, let command { copyButton(agent.title, id: agent.rawValue, text: command) }
        }
    }

    @ViewBuilder
    private var pushAction: some View {
        switch setup.states[.push] {
        case .missing:
            actionButton("Install", item: .push)
        case .outdated:
            actionButton("Update", item: .push)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var statusLineAction: some View {
        if case .missing = setup.states[.statusLine] {
            if setup.windows {
                // The set-up flow runs python3 on the machine, which Windows doesn't have by default.
                copyButton("Copy Prompt", id: "statusline", text: UsageSetup.prompt)
            } else {
                actionButton("Set Up", item: .statusLine)
            }
        }
    }

    @ViewBuilder
    private func actionButton(_ title: String, item: SetupItem) -> some View {
        if setup.busy == item {
            ProgressView()
        } else {
            Button(title) { Task { await setup.perform(item) } }
                .buttonStyle(.bordered)
                .disabled(setup.busy != nil || session.state != .connected)
        }
    }

    private func copyButton(_ title: String, id: String, text: String) -> some View {
        Button(copied == id ? "Copied" : "Copy", systemImage: copied == id ? "checkmark" : "doc.on.doc") {
            Pasteboard.copy(text)
            copied = id
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copied == id { copied = nil }
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Copy \(title)")
    }

    // MARK: Text and icons

    private static func text(for state: CheckState) -> String {
        switch state {
        case .checking: "Checking…"
        case .ready(let detail), .missing(let detail), .outdated(let detail): detail
        case .failed(let reason): "Couldn't check: \(reason)"
        }
    }

    @ViewBuilder
    private static func icon(_ state: CheckState) -> some View {
        switch state {
        case .checking:
            ProgressView()
        case .ready:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .outdated:
            Image(systemName: "arrow.up.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

/// One checklist row: the item's symbol, its name and what was found, and its status or action,
/// centred on the right.
private struct SetupRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    var command: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let command {
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) { trailing }
        }
        .padding(.vertical, 2)
        .frame(minHeight: PlatformMetrics.controlHeight)
    }
}

/// Shows the Setup checklist once per machine, right after it first connects.
@MainActor @Observable
final class FirstConnectSetup {
    struct Pending: Identifiable {
        let id: UUID
        let session: HostSession
    }

    private(set) var pending: Pending?
    private var sessions: SessionStore?

    static func key(_ host: UUID) -> String { "bergr.setup.shown.\(host.uuidString)" }

    func run(sessions: SessionStore) {
        guard self.sessions == nil else { return }
        self.sessions = sessions
        observe()
    }

    /// Looks for a machine that connected and hasn't had its checklist shown yet.
    func observe() {
        guard pending == nil, let sessions else { return }
        let connected = withObservationTracking {
            sessions.ids.compactMap { sessions.existing($0) }.filter { $0.state == .connected && $0.canRunCommands }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard let session = connected.first(where: { !UserDefaults.standard.bool(forKey: Self.key($0.host.id)) }) else { return }
        UserDefaults.standard.set(true, forKey: Self.key(session.host.id))
        pending = Pending(id: session.host.id, session: session)
    }

    func dismissed() {
        pending = nil
        observe()
    }
}

/// Presents the Setup checklist after a machine first connects. Attach once, at the app's root.
struct SetupAfterFirstConnect: ViewModifier {
    let sessions: SessionStore
    @State private var presenter = FirstConnectSetup()

    func body(content: Content) -> some View {
        content
            .task { presenter.run(sessions: sessions) }
            .sheet(item: Binding(get: { presenter.pending }, set: { if $0 == nil { presenter.dismissed() } })) { pending in
                MachineSetupView(session: pending.session)
            }
    }
}
