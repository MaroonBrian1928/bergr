import HerdrKit
import SwiftUI

/// One agent's window (`WindowGroup(for: AgentRef.self)`): the same chat the main window shows.
struct AgentWindow: View {
    let ref: AgentRef
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts

    var body: some View {
        if let host = hosts.hosts.first(where: { $0.id == ref.host }) {
            ChatWindow(session: sessions.session(for: host), address: ref.address)
                .focusedSceneValue(\.agentRef, ref)
                .frame(minWidth: 420, minHeight: 400)
        } else {
            ContentUnavailableView("Machine removed", systemImage: "server.rack",
                                   description: Text("This agent's machine is no longer in Bergr."))
                .frame(minWidth: 420, minHeight: 400)
        }
    }
}

/// One agent's chat. Attaches headless (a chat has no terminal view, so it never resizes the
/// terminal) at the terminal's own size and follows the conversation, like `TerminalScreenView`
/// does on iOS.
struct ChatWindow: View {
    let session: HostSession
    let address: String

    var body: some View {
        ChatWindowContent(session: session, address: address)
            .id(ChatIdentity(session: ObjectIdentifier(session), address: address))
    }
}

private struct ChatIdentity: Hashable {
    let session: ObjectIdentifier
    let address: String
}

private struct ChatWindowContent: View {
    let session: HostSession
    let address: String
    @State private var reading = false
    @State private var launchError: String?
    @State private var model = TerminalScreenModel(theme: TerminalTheme.current(.dark, light: "", dark: ""))
    @State private var feed = ChatFeed()
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @State private var appearsActive = false
    /// The right-hand inspector, open or not, remembered for every chat.
    @AppStorage("bergr.mac.inspector") private var showingInspector = true

    var body: some View {
        let terminal = session.terminal(address)
        let agent = chatAgent(terminal)
        Group {
            if let linked = linkedMachine {
                // Its conversation is on that machine: through this one there's only the terminal.
                ContentUnavailableView {
                    Label(agent == nil ? "Terminal on \(linked)" : "\(agent!.displayName) on \(linked)",
                          systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Bergr reaches \(linked) through \(session.host.name), which carries only the terminal. "
                         + "Open it in your terminal, or add \(linked) as its own machine to get the chat.")
                } actions: {
                    Button("Open in Terminal") {
                        launchError = TerminalLauncher.open(host: session.host, address: address)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let agent {
                ChatView(feed: feed, agent: agent, terminal: terminal, model: model, session: session)
                    .task(id: "\(agent.rawValue) \(session.state == .connected) \(session.connectionRevision)") {
                        guard session.state == .connected, let terminal else { return }
                        model.wantsKeyboard = false
                        model.drawing = false
                        if !model.started {
                            model.start(session: session, address: address, cols: max(terminal.cols, 20), rows: max(terminal.rows, 5))
                        } else {
                            model.reconnect()
                        }
                        let front = terminal.foreground.flatMap {
                            ChatAgent.detect(name: $0.name, argv: $0.argv) == agent ? $0 : nil
                        }
                        feed = session.chatFeed(
                            address: address, agent: agent, pid: front?.pid ?? 0,
                            cwd: front?.cwd ?? terminal.cwd,
                            sessionHint: ChatAgent.sessionHint(argv: terminal.foreground?.argv ?? []))
                    }
            } else {
                ContentUnavailableView(
                    terminal == nil ? "Connecting…" : "No chat for this terminal", systemImage: "terminal",
                    description: Text(terminal == nil ? "Waiting for \(session.host.name)."
                                      : "It isn't running an agent. Open it in your terminal to use it."))
            }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.theme = TerminalTheme.current(scheme, light: lightTheme, dark: darkTheme)
        }
        .onDisappear {
            model.stop(); setReading(false)
            clearFocus()
        }
        .background {
            KeyWindowObserver { active in
                appearsActive = active
            }
            .frame(width: 0, height: 0)
        }
        // Check the line every 3 s while this window is in front.
        .task(id: appearsActive) {
            if appearsActive { await session.keepChecking() }
        }
        // The window in front doesn't get banners about its own agent.
        .onChange(of: appearsActive, initial: true) { _, active in
            setReading(active)
            if active {
                NotificationRouter.shared.focused = (session.host.id, address)
                MacNotifications.shared.focus(AgentRef(host: session.host.id, address: address))
            } else { clearFocus() }
        }
        .focusedSceneValue(\.openTerminal, {
            launchError = TerminalLauncher.open(host: session.host, address: address)
        })
        .focusedSceneValue(\.interruptAgent, { model.press(.escape) })
        .inspector(isPresented: $showingInspector) {
            if let agent = chatAgent(terminal), linkedMachine == nil {
                ChatInspector(feed: feed, agent: agent, terminal: terminal, machine: machineName,
                              model: model, canSetMode: terminal?.isLive == true, session: session)
            } else {
                // No chat to describe: where it runs, still.
                Form {
                    Section("Environment") {
                        LabeledContent("Machine", value: machineName)
                        if let cwd = terminal?.cwd { LabeledContent("Folder", value: ChatInspector.abbreviate(cwd)) }
                        if let program = terminal?.foreground?.name { LabeledContent("Running", value: program) }
                    }
                }
                .formStyle(.grouped)
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open in Terminal", systemImage: "terminal") {
                    launchError = TerminalLauncher.open(host: session.host, address: address)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Inspector", systemImage: "sidebar.right") { showingInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
                    .help(showingInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .alert("Couldn’t Open Terminal", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("OK") { launchError = nil }
        } message: { Text(launchError ?? "") }
        .navigationTitle(terminal?.nameInSpace ?? address)
        .navigationSubtitle(machineName)
    }

    private func chatAgent(_ terminal: Terminal?) -> ChatAgent? {
        #if DEBUG
        // Profiling (`-bergr.demo YES -bergr.stress <turns>`): the demo machine's agents get a chat.
        if session.host.isDemo, UserDefaults.standard.integer(forKey: "bergr.stress") > 0,
           let terminal, terminal.foreground?.name == "agent" { return .claude }
        #endif
        return terminal.flatMap(ChatAgent.detect)
    }

    /// The machine this terminal runs on: a linked machine's name (`popos/t3`), or this connection's.
    private var linkedMachine: String? {
        address.firstIndex(of: "/").map { String(address[..<$0]) }
    }

    private var machineName: String {
        linkedMachine.map { "\($0) · via \(session.host.name)" } ?? session.host.name
    }

    private func setReading(_ active: Bool) {
        guard active != reading else { return }
        reading = active
        if active { session.startLooking(at: address) }
        else { session.stopLooking(at: address) }
    }

    private func clearFocus() {
        if let focused = NotificationRouter.shared.focused, focused.host == session.host.id, focused.address == address {
            NotificationRouter.shared.focused = nil
            MacNotifications.shared.focus(nil)
        }
    }
}
