import HerdrKit
import SwiftUI

/// The detail column: the live terminal screen, with its facts one tap away.
struct TerminalScreenView: View {
    let session: HostSession
    let address: String
    @Binding var expanded: Bool
    /// Two panes side by side: this one draws its own header (see `PaneChrome`) instead of the system bar.
    var pane: PaneChrome?
    @State private var model: TerminalScreenModel
    @State private var showingInfo = false
    @AppStorage(TerminalFont.sizeKey) private var fontSize = TerminalFont.defaultSize
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    /// Open terminals watching (observe) instead of taking them over; remembered.
    @AppStorage("terminal.watch") private var watchByDefault = false
    /// Agents open as a chat instead of their terminal; remembered.
    @AppStorage("terminal.chat") private var chatPreferred = true
    @State private var feed = ChatFeed()
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false

    /// The agent whose conversation can show as a chat. Not for terminals on machines herdr-core
    /// added (`machine/t7`): their files are on another computer.
    private func chatAgent(_ terminal: Terminal?) -> ChatAgent? {
        #if DEBUG
        // `-bergr.demoChat YES`: the demo machine's terminals open as fake chats: the infra agent
        // (the Postgres upgrade) as Codex, the rest as Claude.
        if session.host.isDemo, UserDefaults.standard.bool(forKey: "bergr.demoChat"), terminal != nil {
            return terminal?.cwd.hasSuffix("infra") == true ? .codex : .claude
        }
        #endif
        // Not tied to the line being up: while it reconnects (back from the background) the chat
        // stays and waits, instead of the terminal flashing up until the line is back.
        guard let terminal, !session.host.isDemo, !address.contains("/") else { return nil }
        return ChatAgent.detect(terminal)
    }

    private var theme: TerminalTheme { TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme) }

    init(session: HostSession, address: String, expanded: Binding<Bool>, pane: PaneChrome? = nil) {
        self.pane = pane
        self.session = session
        self.address = address
        _expanded = expanded
        // The theme from the start, so the screen never shows other colors while it attaches.
        // (The color scheme isn't known yet here; onChange below corrects it before the first frame.)
        let defaults = UserDefaults.standard
        let style = UITraitCollection.current.userInterfaceStyle
        let theme = TerminalTheme.current(
            style == .dark ? .dark : .light,
            light: defaults.string(forKey: TerminalTheme.lightKey) ?? TerminalTheme.defaultLight,
            dark: defaults.string(forKey: TerminalTheme.darkKey) ?? TerminalTheme.defaultDark)
        _model = State(initialValue: TerminalScreenModel(theme: theme))
    }

    var body: some View {
        let terminal = session.terminal(address)
        let agent = chatAgent(terminal)
        let chat = agent != nil && chatPreferred
        ZStack(alignment: .top) {
            // Before the first frame, the theme's background (the frame's afterwards: programs may change it).
            Color(uiColor: UIColor(model.frame.cols == 0 ? theme.backgroundRGB : model.frame.background)).ignoresSafeArea()
            if terminal?.isLive ?? false || model.phase == .live {
                TerminalCanvas(
                    model: model, fontSize: $fontSize, fontFamily: fontFamily, dark: theme.dark,
                    // Unfolded, from the terminal's left part: swiping right brings back the lists,
                    // swiping left pushes them away. (Folded, the edge is the stack's back swipe.)
                    onEdgeSwipe: sizeClass == .regular ? { toRight in
                        if toRight == expanded { withAnimation { expanded = !toRight } }
                    } : nil,
                    drawing: !chat
                ) { cols, rows in
                    if case .attaching = model.phase {
                        let watch = watchByDefault || session.watchNext == address
                        if session.watchNext == address { session.watchNext = nil }
                        model.start(session: session, address: address, cols: cols, rows: rows, watch: watch)
                    } else {
                        model.viewSizeChanged(cols: cols, rows: rows)
                    }
                }
                // The canvas keeps its full size and makes room for the keyboard itself.
                .ignoresSafeArea(.keyboard)
            }
            if chat, let agent {
                // The terminal stays attached underneath: replies are typed into it.
                ChatView(feed: feed, agent: agent, terminal: terminal, model: model,
                         onInfo: { showingInfo = true }, session: session,
                         pane: paneChrome(terminal, extra: AnyView(chatSwitch(agent: agent, chat: chat))))
            } else {
                overlay(terminal)
            }
            if !chat, let terminal, terminal.isLive, terminal.status?.state == "blocked", model.phase == .live,
               AnswerParser.isAsking(model.frame.textLines) {
                // Only when something on screen can be answered: otherwise Yes/No would type
                // letters, and the bar would cover the input (e.g. pasting a login code).
                NeedsYouBar(status: terminal.status, model: model, dark: theme.dark)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chat, let chrome = paneChrome(terminal, extra: AnyView(EmptyView())) {
                PaneHeader(chrome: chrome, backdrop: Color(uiColor: UIColor(theme.backgroundRGB))) { terminalButtons(agent: agent, chat: chat) }
            }
        }
        .navigationTitle(pane == nil ? terminal?.nameInSpace ?? address : "")
        // Watching, the size being watched instead (the screen shows it as an outline).
        .navigationSubtitle(pane == nil ? subtitle(terminal) : "")
        .navigationBarTitleDisplayMode(.inline)
        // The title bar sits on the terminal's background: match its brightness, not the app's.
        .toolbarColorScheme(chat ? colorScheme : theme.dark ? .dark : .light, for: .navigationBar)
        .onChange(of: theme, initial: true) { _, theme in model.theme = theme }
        // Back from the background (or a dropped line): the line is new, and the terminal's
        // channel went with the old one. Attach again, or a reply typed in the chat goes nowhere
        // until the terminal itself is opened.
        // (The same model attaches again: a new one would wait for the terminal to report its
        // size, which a hidden terminal behind the chat never does.)
        .onChange(of: session.state == .connected) { _, connected in
            if connected, model.started { model.reconnect() }
        }
        // Kept connected in the background, the line may never visibly drop while the channel
        // died with the app suspended (back from a notification): attach again anyway.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasInBackground = true }
            guard phase == .active, wasInBackground else { return }
            wasInBackground = false
            if session.state == .connected, model.started { model.reconnect() }
        }
        .toolbar {
            if pane == nil {
                ToolbarItemGroup(placement: .topBarTrailing) { terminalButtons(agent: agent, chat: chat) }
            }
        }
        // With two panes the column's bar is hidden (each pane has its own header).
        .toolbar(pane == nil ? .automatic : .hidden, for: .navigationBar)
        // The session follows the conversation and keeps following it if this screen goes away
        // for a moment. Keyed by the agent only: the foreground process changes whenever the
        // agent runs a command, and the feed finds a new conversation in the same terminal itself.
        // Also keyed by the line being up: going to the background closes the line and ends the
        // feeds, so coming back must ask for a new one (the old one stays on screen meanwhile).
        .task(id: chat ? agent.map { "\($0.rawValue) \(session.state == .connected)" } : nil) {
            guard chat, let agent, let terminal, session.state == .connected else { return }
            model.wantsKeyboard = false
            // The agent's own process if it's in front; else the terminal's folder finds it.
            let front = terminal.foreground.flatMap { fg in
                ChatAgent.detect(name: fg.name, argv: fg.argv) == agent ? fg : nil
            }
            feed = session.chatFeed(
                address: address, agent: agent, pid: front?.pid ?? 0, cwd: front?.cwd ?? terminal.cwd,
                sessionHint: ChatAgent.sessionHint(argv: front?.argv ?? terminal.foreground?.argv ?? []))
        }
        .sheet(isPresented: $showingInfo) {
            NavigationStack {
                TerminalDetailView(session: session, address: address)
                    .toolbar {
                        Button("Done") { showingInfo = false }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .onChange(of: terminal.map { [$0.cols, $0.rows] }) { _, size in
            if let size { model.remoteSizeChanged(cols: size[0], rows: size[1]) }
        }
        // "Watch" from the list while this terminal is already open.
        .onChange(of: session.watchNext) { _, next in
            guard next == address, model.phase == .live else { return }
            session.watchNext = nil
            model.setWatching(true)
        }
        // On screen: its agent counts as read (herdr's shared `herdr.seen`).
        .onAppear { session.startLooking(at: address) }
        .onDisappear {
            model.stop()
            session.stopLooking(at: address)
        }
    }

    private func subtitle(_ terminal: Terminal?) -> String {
        // Watching, the size being watched instead (the screen shows it as an outline).
        model.watching && terminal != nil
            ? "Watching · \(terminal!.cols)×\(terminal!.rows)" : terminal.flatMap(spaceName) ?? ""
    }

    private func paneChrome(_ terminal: Terminal?, extra: AnyView) -> PaneChrome? {
        guard var chrome = pane else { return nil }
        chrome.title = terminal?.nameInSpace ?? address
        chrome.subtitle = subtitle(terminal)
        chrome.extra = extra
        return chrome
    }

    @ViewBuilder
    private func chatSwitch(agent: ChatAgent?, chat: Bool) -> some View {
        if agent != nil {
            Button(chat ? "Show Terminal" : "Show Chat",
                   systemImage: chat ? "apple.terminal" : "bubble.left.and.text.bubble.right")
            {
                chatPreferred.toggle()
            }
        }
    }

    /// The title bar's buttons (or a pane header's).
    @ViewBuilder
    private func terminalButtons(agent: ChatAgent?, chat: Bool) -> some View {
        chatSwitch(agent: agent, chat: chat)
        if model.phase == .live && !chat {
            // Watching is remembered for the next terminal; typing ends it only here.
            Button(model.watching ? "Take Over" : "Watch Only",
                   systemImage: model.watching ? "eye.fill" : "eye")
            {
                watchByDefault = !model.watching
                model.setWatching(!model.watching)
            }
            Button(model.wantsKeyboard ? "Hide Keyboard" : "Show Keyboard",
                   systemImage: model.wantsKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
            {
                model.wantsKeyboard.toggle()
            }
        }
        // Hiding and showing the lists is the split view's own sidebar button.
        // In the chat, Info is in its ⋯ menu.
        if !chat { Button("Info", systemImage: "info.circle") { showingInfo = true } }
    }

    /// The space (or machine) the terminal belongs to, as the list shows it.
    private func spaceName(_ terminal: Terminal) -> String? {
        TerminalGrouping.bySpace(session.terminals, layout: session.layout)
            .first { $0.rows.contains { $0.terminal.address == terminal.address } }?.title
    }

    @ViewBuilder
    private func overlay(_ terminal: Terminal?) -> some View {
        switch model.phase {
        case .attaching:
            if terminal?.isLive == false {
                TerminalDetailView(session: session, address: address)
            } else {
                ProgressView("Opening terminal…").padding(.top, 40).tint(.white).foregroundStyle(.white)
            }
        case .live:
            // Watching needs no banner: the subtitle says so, and an outline shows the size.
            if model.sizeOwnedElsewhere && !model.watching {
                Banner(text: "Another viewer sets the size. Tap the screen and type to take over.",
                       systemImage: "rectangle.on.rectangle")
            } else if model.scrolledBack {
                Button {
                    model.scroll(toBottom: true)
                } label: {
                    Banner(text: "Scrolled back. Tap to return to the live screen.", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.plain)
            }
        case .ended(let reason):
            Banner(text: reason, systemImage: "stop.circle")
        case .failed(let message):
            Banner(text: message, systemImage: "exclamationmark.triangle")
        }
    }
}

private struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 8)
    }
}

/// A blocked agent waits for an answer: the usual replies as buttons, so there's no need to type.
struct NeedsYouBar: View {
    let status: TerminalStatus?
    let model: TerminalScreenModel
    var dark = true
    /// Called with the answer given, for the chat's record.
    var onAnswer: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(status?.title ?? "Waiting for you").lineLimit(2)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.needsYou)
            }
            .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Button { onAnswer?("Yes"); model.type("y") } label: {
                    Label("Yes", systemImage: "checkmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.needsYou)
                .foregroundStyle(Color(red: 0x30 / 255, green: 0x34 / 255, blue: 0x38 / 255))
                Button { onAnswer?("No"); model.type("n") } label: {
                    Label("No", systemImage: "xmark").fixedSize().frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Button { onAnswer?("Return"); model.press(.enter) } label: { Image(systemName: "return").fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Return")
                Button { onAnswer?("Cancelled (esc)"); model.press(.escape) } label: { Text("esc").font(.callout.monospaced()).fixedSize() }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Escape")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}
