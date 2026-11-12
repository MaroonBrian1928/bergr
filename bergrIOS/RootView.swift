import HerdrKit
import SwiftUI

/// Two columns when unfolded (terminals | terminal), a stack when folded. The machine is picked
/// from the sidebar's title, so it doesn't need a column of its own.
struct RootView: View {
    @Environment(HostStore.self) private var hosts
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasInBackground = false
    @State private var sessions = SessionStore()
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The machine shown in the sidebar, remembered across launches.
    @AppStorage("selectedHost") private var storedHost = ""
    @State private var selectedTerminal: String?
    @State private var columns = NavigationSplitViewVisibility.all
    /// On a phone (one column at a time): which column shows. Opening an agent moves to its chat.
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    @State private var showingSettings = false
    @State private var showingNewSession = false
    /// Set by an intent ("Start session") for the New Session sheet it opens.
    @State private var newSessionPrefill: NewSessionPrefill?
    /// A second conversation shown beside the open one (iPad, the unfolded Duo).
    @State private var beside: Pane?
    struct Pane: Hashable { let host: Host.ID; let address: String }
    @State private var notifier: AgentNotifier?
    private let router = NotificationRouter.shared

    private var selectedHost: Binding<Host.ID?> {
        Binding(
            get: {
                let ids = hosts.hosts.map(\.id)
                if let stored = UUID(uuidString: storedHost), ids.contains(stored) { return stored }
                return ids.first
            },
            set: { storedHost = $0?.uuidString ?? "" })
    }

    var body: some View {
        #if DEBUG
        // `-bergr.chatPreview YES`: the chat view with sample content, for checking its design.
        if UserDefaults.standard.bool(forKey: "bergr.chatPreview") {
            ChatPreviewScreen()
        } else {
            main.modifier(TrustPrompt(sessions: sessions)).background { agentShortcuts }
                .background { UsageAlertsHost(sessions: sessions) }
        }
        #else
        main.modifier(TrustPrompt(sessions: sessions)).background { agentShortcuts }
            .background { UsageAlertsHost(sessions: sessions) }
        #endif
    }

    @ViewBuilder
    private func detailPanes(host: Host, address: String) -> some View {
                let expanded = Binding(
                    get: { columns == .detailOnly },
                    set: { columns = $0 ? .detailOnly : .all })
                if horizontalSizeClass == .regular, let pane = beside,
                   let besideHost = hosts.hosts.first(where: { $0.id == pane.host }) {
                    // Two conversations side by side. The column has a single system bar and every
                    // toolbar in it lands there, so that bar is hidden and each pane draws its own header.
                    HStack(spacing: 10) {
                        TerminalScreenView(
                            session: sessions.session(for: host), address: address, expanded: expanded,
                            pane: PaneChrome(buttonLabel: "Show Lists", buttonImage: "sidebar.leading",
                                             action: { withAnimation { columns = columns == .all ? .detailOnly : .all } },
                                             identifier: "primary"))
                            .id("\(host.id)/\(address)")
                            .clipShape(.rect(cornerRadius: 26, style: .continuous))
                        TerminalScreenView(
                            session: sessions.session(for: besideHost), address: pane.address,
                            expanded: .constant(false),
                            pane: PaneChrome(buttonLabel: "Close", buttonImage: "xmark",
                                             action: { withAnimation(.smooth(duration: 0.3)) { beside = nil } },
                                             identifier: "beside"))
                            .id("beside/\(pane.host)/\(pane.address)")
                            .clipShape(.rect(cornerRadius: 26, style: .continuous))
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    // Two cards with a gutter between them, like two windows, not one screen cut in half.
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                } else {
                    TerminalScreenView(session: sessions.session(for: host), address: address, expanded: expanded)
                        .id("\(host.id)/\(address)")
                }
    }

    private var main: some View {
        NavigationSplitView(columnVisibility: $columns, preferredCompactColumn: $compactColumn) {
            // Every agent on every machine first; one machine's terminals, machines and settings
            // are one tap away.
            AgentsView(sessions: sessions,
                       openBeside: horizontalSizeClass == .regular ? { host, address in openBeside(host: host, address: address) } : nil)
            { host, address in open(host: host, address: address) }
            // The title sits on the same row as the buttons.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        SidebarView(sessions: sessions, selectedHost: selectedHost, selectedTerminal: $selectedTerminal)
                    } label: {
                        Label("Machines", systemImage: "server.rack")
                    }
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    Button("New Session", systemImage: "plus") { showingNewSession = true }
                }
            }
            .sheet(isPresented: $showingNewSession) {
                NewSessionView(sessions: sessions, prefill: newSessionPrefill) { host, address in open(host: host, address: address) }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet(addDemo: {}, sessions: sessions) { showingSettings = false }
            }
            .modifier(PadSidebarWidth())
        } detail: {
            if let host = hosts.hosts.first(where: { $0.id == selectedHost.wrappedValue }),
               let address = selectedTerminal {
                detailPanes(host: host, address: address)
            } else if horizontalSizeClass == .regular {
                ContentUnavailableView(
                    "No terminal selected", systemImage: "terminal",
                    description: Text("Pick an agent or terminal from the list to open it."))
            } else {
                // On a phone this column only shows while a push is under way (the selection lands
                // a moment after the tap): a blank page, not a "nothing selected" message.
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .navigationSplitViewStyle(.balanced)
        #if DEBUG
        // `-bergr.testMachine user@host[:port]` (simulator testing against a real machine): a
        // key of its own ("Simulator", a software key there) and that machine, ready to connect.
        // Its public line goes to Documents/simulator-key.pub, for the machine's authorized_keys.
        .task {
            guard let spec = UserDefaults.standard.string(forKey: "bergr.testMachine"),
                  let at = spec.firstIndex(of: "@") else { return }
            let user = String(spec[..<at])
            let rest = spec[spec.index(after: at)...]
            let parts = rest.split(separator: ":")
            let address = String(parts[0])
            let port = parts.count > 1 ? Int(parts[1]) ?? 22 : 22
            let key = keys.keys.first { $0.label == "Simulator" }
                ?? keys.generate(label: "Simulator", requireBiometry: false)
            guard let key else { return }
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? (key.authorizedKeysLine + " bergr-simulator\n")
                    .write(to: docs.appendingPathComponent("simulator-key.pub"), atomically: true, encoding: .utf8)
            }
            if !hosts.hosts.contains(where: { $0.target.host == address && $0.target.username == user }) {
                hosts.save(Host(name: address, target: SSHTarget(host: address, port: port, username: user), keyID: key.id))
            }
        }
        // `-bergr.demo YES` (videos, UI tests on a device with real machines): open the demo machine.
        .task {
            if UserDefaults.standard.bool(forKey: "bergr.demo") { storedHost = hosts.addDemo().id.uuidString }
        }
        #endif
        .task {
            if notifier == nil {
                Delivery.migrate()
                Delivery.apply()
                let notifier = AgentNotifier(sessions: sessions)
                notifier.start()
                self.notifier = notifier
                // The Lock Screen and Dynamic Island summary while kept connected in the background.
                LiveActivityController.run(sessions: sessions)
                PushRegistration.shared.run(sessions: sessions)
                // Notification buttons answer through these sessions, connecting on demand.
                let connect = AnswerFlow.live(sessions: sessions, hosts: hosts, keys: keys)
                AnswerNotifications.shared.configure(AnswerFlow(
                    screen: { await connect($0.host, $0.address) },
                    openChat: { router.pending = ($0, $1) },
                    replyScreen: { await connect($0.host, $0.address) }))
            }
            // Wi-Fi ↔ cellular, a VPN: lines may be dead without knowing; check them at once.
            NetworkWatcher.shared.start { [sessions, keys] in sessions.probeAll(keys: keys) }
        }
        .modifier(PushPrompts(inSettings: false))
        .modifier(SetupAfterFirstConnect(sessions: sessions))
        // The chat on screen doesn't alert about itself.
        .onChange(of: selectedTerminal, initial: true) { _, address in
            notifier?.focusedAddress = selectedHost.wrappedValue.flatMap { host in address.map { (host, $0) } }
        }
        // A tapped alert opens its terminal.
        // initial: also when a tap launched the app from scratch, before this view existed.
        .onChange(of: router.pending?.address, initial: true) {
            guard let target = router.pending else { return }
            router.pending = nil
            open(host: target.host, address: target.address)
        }
        .onChange(of: selectedHost.wrappedValue) {
            selectedTerminal = nil
        }
        // Siri, Shortcuts or a control launched the app: the queued request is routed here.
        .task { handleIntents() }
        .onChange(of: showingNewSession) { _, showing in
            if !showing { newSessionPrefill = nil }
        }
        .onChange(of: hosts.hosts) { _, current in
            // Edited or deleted machines get a fresh session.
            for host in current where sessions.existing(host.id).map({ $0.host != host }) ?? false {
                sessions.remove(host.id)
            }
            for id in sessions.ids where !current.contains(where: { $0.id == id }) {
                sessions.remove(id)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                wasInBackground = true
                // Kept connected in the background (Settings → When Bergr isn't open): the sessions stay up, so
                // agents that need you can alert. Otherwise they pause, as before.
                if KeepAlive.shared.enabled {
                    KeepAlive.shared.appEnteredBackground()
                } else {
                    sessions.pauseAll()
                    keys.forgetUnlocked()
                }
            case .active:
                handleIntents()
                KeepAlive.shared.appEnteredForeground()
                if wasInBackground {
                    wasInBackground = false
                    sessions.resumeAfterBackground(keys: keys)
                } else {
                    sessions.resumePaused(keys: keys)
                }
            default: break
            }
        }
    }
}

extension RootView {
    /// Shows a terminal's chat on any machine. Switching machines clears the selected terminal
    /// (onChange below), so the terminal is set on the next turn, after that has run.
    /// ⌘1…⌘9 open the agents in the order the Agents list shows them.
    private var agentShortcuts: some View {
        let agents: [(Host.ID, String)] = hosts.hosts.flatMap { host in
            AgentsOrdering.ordered(sessions.session(for: host).terminals.filter(\.isLive)).map { (host.id, $0.address) }
        }
        return ForEach(0..<min(9, agents.count), id: \.self) { i in
            Button("Open agent \(i + 1)") { open(host: agents[i].0, address: agents[i].1) }
                .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Opens a second conversation next to the open one; with none open yet, it just opens.
    func openBeside(host: Host.ID, address: String) {
        guard selectedTerminal != nil else { return open(host: host, address: address) }
        let pane = Pane(host: host, address: address)
        if pane == Pane(host: selectedHost.wrappedValue ?? host, address: selectedTerminal ?? "") { return }
        withAnimation(.smooth(duration: 0.3)) { beside = pane }
    }

    /// Routes what App Intents queued (see `IntentQueue`): opens the agent's chat, with the text in
    /// its reply draft for the existing reply path to send; or opens New Session prefilled.
    private func handleIntents() {
        for item in IntentQueue.take() {
            switch item {
            case .message(let host, let address, let text):
                guard let id = UUID(uuidString: host) else { continue }
                let key = "\(id.uuidString)|\(address)"
                let kept = ReplyDrafts.text(for: key)
                ReplyDrafts.set(kept.isEmpty ? text : kept + "\n" + text, for: key)
                router.pending = (id, address)
            case .newSession:
                guard let prefill = NewSessionPrefill(item) else { continue }
                newSessionPrefill = prefill
                showingNewSession = true
            case .openNeedsYou:
                guard let row = AgentCatalog.needingYou(AgentsSnapshot.load()).first,
                      let id = UUID(uuidString: row.host) else { continue }
                router.pending = (id, row.address)
            }
        }
    }

    func open(host: Host.ID, address: String) {
        // Opening the conversation that's beside swaps it into the main pane.
        if beside == Pane(host: host, address: address) { beside = nil }
        storedHost = host.uuidString
        Task { @MainActor in
            selectedTerminal = address
            compactColumn = .detail
        }
    }
}

/// An iPad has room for the rows' titles in the list column; elsewhere (the unfolded Duo) the
/// column keeps the system's width.
private struct PadSidebarWidth: ViewModifier {
    func body(content: Content) -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            content.navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 480)
        } else {
            content
        }
    }
}
