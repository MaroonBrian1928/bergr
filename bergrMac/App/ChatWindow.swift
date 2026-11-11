import HerdrKit
import SwiftUI

/// Stub (chunk A refines): one agent's chat. Attaches headless (a chat has no terminal view) at
/// the terminal's own size and follows the conversation, like `TerminalScreenView` does on iOS.
struct ChatWindow: View {
    let session: HostSession
    let address: String

    @State private var model = TerminalScreenModel(theme: TerminalTheme.current(.dark, light: "", dark: ""))
    @State private var feed = ChatFeed()
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme

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
        .onDisappear { model.stop(); session.stopLooking(at: address) }
        .onAppear { session.startLooking(at: address) }
        .navigationTitle(terminal?.nameInSpace ?? address)
    }
}
