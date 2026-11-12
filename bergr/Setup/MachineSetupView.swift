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
                if session.state != .connected {
                    Section {
                        Label("Connect to \(session.host.name) to check it.", systemImage: "bolt.horizontal")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    row(.core) { EmptyView() }
                    row(.python) { EmptyView() }
                } header: {
                    Text("Machine")
                }
                Section {
                    ForEach(AgentCLI.allCases) { agent in agentRow(agent) }
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Bergr runs these agents on the machine. Install the ones you use; Bergr shows what it finds.")
                }
                Section {
                    row(.push) { pushAction }
                    row(.statusLine) { statusLineAction }
                } header: {
                    Text("Bergr on the machine")
                } footer: {
                    if let error = setup.actionError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("The push helper sends alerts when an agent needs you. The status line lets the chat show context and plan usage.")
                    }
                }
            }
            .navigationTitle("Setup for \(session.host.name)")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Recheck") { Task { await setup.check() } }
                        .disabled(session.state != .connected || setup.busy != nil)
                }
            }
            .task(id: session.state == .connected) {
                if session.state == .connected { await setup.check() }
            }
        }
    }

    // MARK: Rows

    private func row<Action: View>(_ item: SetupItem, @ViewBuilder action: () -> Action) -> some View {
        let state = setup.states[item] ?? .checking
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(Self.text(for: state))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Self.icon(state)
            action()
        }
        .frame(minHeight: PlatformMetrics.controlHeight)
        .accessibilityIdentifier("setup-\(item.rawValue)")
    }

    private func agentRow(_ agent: AgentCLI) -> some View {
        let state = setup.agents[agent] ?? .checking
        let command = agent.installCommand(windows: setup.windows)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title)
                Text(Self.text(for: state))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if case .missing = state, let command {
                    Text(command)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            Self.icon(state)
            if case .missing = state, let command {
                copyButton(agent.title, id: agent.rawValue, text: command)
            }
        }
        .frame(minHeight: PlatformMetrics.controlHeight)
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
