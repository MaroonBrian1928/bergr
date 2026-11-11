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

    @State private var model = TerminalScreenModel(theme: TerminalTheme.current(.dark, light: "", dark: ""))
    @State private var feed = ChatFeed()
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let terminal = session.terminal(address)
        let agent = terminal.flatMap(ChatAgent.detect)
        Group {
            if let agent {
                ChatView(feed: feed, agent: agent, terminal: terminal, model: model, session: session)
                    .task(id: "\(agent.rawValue) \(session.state == .connected)") {
                        guard session.state == .connected, let terminal else { return }
                        model.wantsKeyboard = false
                        if !model.started {
                            model.start(session: session, address: address, cols: max(terminal.cols, 20), rows: max(terminal.rows, 5))
                        }
                        feed = session.chatFeed(
                            address: address, agent: agent, pid: terminal.foreground?.pid ?? 0,
                            cwd: terminal.foreground?.cwd ?? terminal.cwd,
                            sessionHint: ChatAgent.sessionHint(argv: terminal.foreground?.argv ?? []))
                    }
            } else {
                ContentUnavailableView(
                    terminal == nil ? "Connecting…" : "Not an agent", systemImage: "bubble.left.and.text.bubble.right",
                    description: Text(terminal == nil ? "Waiting for \(session.host.name)." : "This terminal has no chat."))
            }
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            model.theme = TerminalTheme.current(scheme, light: lightTheme, dark: darkTheme)
        }
        .onDisappear {
            model.stop(); session.stopLooking(at: address)
            clearFocus()
        }
        .onAppear { session.startLooking(at: address) }
        // The window in front doesn't get banners about its own agent.
        .onChange(of: appearsActive, initial: true) { _, active in
            if active {
                NotificationRouter.shared.focused = (session.host.id, address)
                MacNotifications.shared.focus(AgentRef(host: session.host.id, address: address))
            } else { clearFocus() }
        }
        .focusedSceneValue(\.interruptAgent, { model.press(.escape) })
        .navigationTitle(terminal?.nameInSpace ?? address)
        .navigationSubtitle(session.host.name)
    }

    private func clearFocus() {
        if let focused = NotificationRouter.shared.focused, focused.host == session.host.id, focused.address == address {
            NotificationRouter.shared.focused = nil
            MacNotifications.shared.focus(nil)
        }
    }
}
