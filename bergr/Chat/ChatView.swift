import HerdrKit
import SwiftUI

/// An agent's conversation as a chat. Replies go to the terminal through herdr-core, as typing.
struct ChatView: View {
    let feed: ChatFeed
    let agent: ChatAgent
    let terminal: Terminal?
    let model: TerminalScreenModel
    /// Opens the terminal's details (the screen's Info sheet).
    var onInfo: (() -> Void)?
    /// The machine's connection, for uploading attached images (none in the design preview).
    var session: HostSession?
    /// Set when two panes share the screen: the chat draws this header instead of using the system bar.
    var pane: PaneChrome?
    #if DEBUG
    /// The design preview shows the working state without an agent behind it.
    var previewWorking = false
    #endif

    @State private var draft = ""
    @State private var attachments: [ChatAttachment] = []
    @State private var sendError: String?
    /// Sent replies, shown at once and until the agent's conversation has them.
    @State private var pending: [Pending] = []
    @State private var sent = 0
    /// Each Send Now: a firmer tap than a send, felt as stopping the agent.
    @State private var pushes = 0
    @State private var showingUsage = false
    @State private var selecting: SelectableMessage?
    @State private var viewing: ViewedImage?
    /// The Claude Code version whose update banner was closed: it stays away until a newer one
    /// is installed.
    @AppStorage("chat.dismissedClaudeUpdate") private var dismissedUpdate = ""
    @State private var showingModels = false
    /// When this chat first saw the agent working, for a timer that doesn't restart on every
    /// redraw when herdr-core doesn't say when its status changed.
    @State private var workingSeen: Date?
    /// Where the conversation is scrolled; starts at the latest message.
    @State private var position = ScrollPosition(edge: .bottom)
    /// While the list moves, its rows don't answer the pointer: on the Mac every pointer move over
    /// moving content was checked against every message (a quarter of the time spent scrolling).
    @State private var scrolling = false
    /// How many rows to draw. The list isn't lazy, so a long conversation drawn whole is slow to
    /// open and to scroll; the latest rows show, earlier ones a tap away. Search looks at all.
    @State private var rowLimit = Self.rowPage
    private static let rowPage = 150
    /// Scrolled well up from the latest message: a button brings it back.
    @State private var awayFromLatest = false
    /// The search field at the top shows while searching; closing it clears the search.
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// The search field's text; while it has any, only the matching rows show.
    @State private var query = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Pending: Identifiable, Equatable {
        let id = UUID()
        let text: String
        var at = Date.now
        var images = false
        /// No sign of it in the conversation, and the agent didn't start working: offer Retry.
        var failed = false
        /// Sent now (the agent was stopped for it), not waiting in its queue.
        var pushed = false
        /// Waiting in the agent's queue: sent while it worked.
        var queued = false

        /// Whether the conversation has this reply. With images it comes back with the image
        /// paths (or "[Image #1]") in front of the words, so the words only have to end it.
        func isIn(_ said: Set<String>) -> Bool {
            if said.contains(text) { return true }
            return images && !text.isEmpty && said.contains { $0.hasSuffix(text) }
        }
    }

    private var palette: ChatPalette { .of(colorScheme) }
    private var state: String? {
        #if DEBUG
        if previewWorking || feed.demoWorking { return "working" }
        #endif
        return terminal?.status?.state
    }
    private var canType: Bool {
        #if DEBUG
        // The design preview's live mode can type (no terminal behind it), to test the keyboard.
        if UserDefaults.standard.bool(forKey: "bergr.chatPreviewLive") { return true }
        #endif
        // Also while the terminal (re)attaches, e.g. back from the background: what's sent waits
        // and goes once it's attached, so the keyboard isn't taken away meanwhile.
        return (model.phase == .live || model.started) && terminal?.isLive == true
    }
    /// The trimmed search text, or nil when not searching.
    private var search: String? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    /// Critically damped: things settle without overshoot. Crossfades only, with Reduce Motion.
    private var motion: Animation? { reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35) }
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 12))
    }

    var body: some View {
        let all = shownRows
        let hidden = search == nil ? max(0, all.count - rowLimit) : 0
        let shown = hidden > 0 ? Array(all.suffix(rowLimit)) : all
        let shownReplies = shownPending
        ScrollView {
            // Not lazy: every row is measured, so the list never grows by an estimate and shrinks
            // back (a jump on every arrival), and a conversation about one screen tall doesn't flip
            // between estimated and real heights (the list drifting by itself).
            VStack(alignment: .leading, spacing: 18) {
                if search == nil { placeholder }
                if hidden > 0 {
                    Button {
                        let first = shown.first?.id
                        rowLimit += Self.rowPage
                        // Stay where you were: the earlier rows land above it.
                        if let first { position.scrollTo(id: first, anchor: .top) }
                    } label: {
                        Label("Earlier messages", systemImage: "arrow.up")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .foregroundStyle(palette.secondary)
                    .accessibilityHint("\(hidden) more")
                }
                Group {
                    ForEach(shown) { row in
                        rowView(row)
                            // A row is hit as its box, not its text's outline: matching the outline
                            // on every pointer move made scrolling slow on the Mac.
                            .contentShape(.rect)
                            .transition(transition(for: row))
                    }
                }
                // The read conversation arrives in one step: fade it in where it lands (no slide).
                .opacity(feed.items.isEmpty ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: feed.items.isEmpty)
                // Sub-agents whose starting tool call isn't in the conversation (yet).
                if search == nil, !looseSubagents.isEmpty {
                    SubagentGroup(agents: looseSubagents, palette: palette)
                }
                // A sent reply shows at once; when the conversation has it, the real one takes
                // its place without moving, and this one goes in the same instant.
                ForEach(shownReplies) { reply in
                    VStack(alignment: .trailing, spacing: 6) {
                        UserBubble(text: reply.text, palette: palette)
                            .opacity(0.55)
                            // Sent while the agent works, it waits in the agent's queue: long-press
                            // can stop the agent so it's read now.
                            .contextMenu {
                                if state == "working", !reply.failed {
                                    Button("Send Now", systemImage: "bolt.fill") { pushNow() }
                                }
                                copyButton(reply.text)
                            }
                            .accessibilityLabel(reply.failed ? "Not delivered: \(reply.text)" : "Sending: \(reply.text)")
                        if !reply.failed, reply.queued || reply.pushed {
                            Label(reply.pushed ? "Sending now" : "Queued, the agent reads it after this step",
                                  systemImage: reply.pushed ? "bolt.fill" : "clock")
                                .font(.caption)
                                .foregroundStyle(reply.pushed ? palette.accent : palette.secondary)
                                .contentTransition(.symbolEffect(.replace))
                                .transition(.opacity)
                        }
                        if reply.failed {
                            HStack(spacing: 12) {
                                Label("Not delivered", systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(palette.secondary)
                                Button("Retry") { retry(reply) }
                                    .font(.footnote.weight(.semibold))
                                    .frame(minHeight: 44)
                                Button("Discard", systemImage: "xmark") {
                                    withAnimation(motion) { pending.removeAll { $0.id == reply.id } }
                                }
                                .labelStyle(.iconOnly)
                                .font(.footnote)
                                .foregroundStyle(palette.secondary)
                                .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.asymmetric(insertion: arrival, removal: .identity))
                }
                if search == nil, state == "working" {
                    WorkingRow(agent: agent, detail: terminal?.status?.msg ?? terminal?.status?.title, palette: palette,
                               since: workingSince)
                        // It makes way for the reply without an animation of its own to fight it.
                        .transition(.asymmetric(insertion: .opacity, removal: .identity))
                }
                if search != nil, shown.isEmpty, shownReplies.isEmpty {
                    Text("No matches")
                        .font(.footnote)
                        .foregroundStyle(palette.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                        .transition(.opacity)
                }
            }
            .allowsHitTesting(!scrolling)
            // Not a scroll target layout: with one, the scroll position followed the top row as
            // the list scrolled, and each change rebuilt the chat and redrew its text (slow on the
            // Mac). Showing earlier rows still scrolls to the old first row by its id.
            .animation(motion, value: shown.count)
            .animation(motion, value: feed.items.count)
            .animation(motion, value: feed.subagents.count)
            .animation(motion, value: pending)
            .animation(motion, value: state)
            .animation(motion, value: search)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Room between the last message and the reply bar floating over it.
            .padding(.bottom, 28)
            // A readable line length on a wide screen (iPad, the unfolded Duo), centered.
            .frame(maxWidth: Self.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .onScrollPhaseChange { _, phase in
            if scrolling != phase.isScrolling { scrolling = phase.isScrolling }
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        #if DEBUG
        .modifier(BounceProbe(feed: feed, terminal: terminal, model: model, state: state,
                              on: UserDefaults.standard.bool(forKey: "bergr.bounceProbe")))
        #endif
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY
        } action: { _, below in
            // Shows well above the bottom, hides only near it again: no flicker at the edge.
            let away = awayFromLatest ? below > 150 : below > 600
            if away != awayFromLatest { withAnimation(motion) { awayFromLatest = away } }
        }
        // Over the conversation, not in the bar below it: showing it mustn't move the list (which
        // would change the distance to the bottom and hide it again, over and over).
        .overlay(alignment: .bottomTrailing) {
            if awayFromLatest {
                Button {
                    withAnimation(motion) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(palette.text)
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Jump to latest")
                .padding(.trailing, 16)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .scrollDismissesKeyboard(.interactively)
        // Where the conversation meets the floating bars, it softens under them instead of a hard cut.
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        // A problem is felt as well as read; a change that went through is felt as done.
        .sensoryFeedback(.error, trigger: sendError) { _, new in new != nil }
        .sensoryFeedback(.success, trigger: feed.items.last?.id) { _, _ in
            if case .decision? = feed.items.last?.kind { return true } else { return false }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let pane { PaneHeader(chrome: pane, backdrop: palette.background) { chatButtons } }
                if searching { searchBar.transition(.opacity) }
            }
        }
        // The reply bar floats over the conversation, which scrolls on under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
        }
        .background(palette.background)
        .onChange(of: feed.items) { confirmPending() }
        .onChange(of: state, initial: true) { _, now in workingSeen = now == "working" ? (workingSeen ?? .now) : nil }
        .toolbar { if pane == nil { chatToolbar } }
        .sheet(isPresented: $showingModels) {
            ModelSheet(models: feed.models, current: currentModel,
                       effort: feed.usage?.effort ?? agyStatus?.effort ?? feed.chosenEffort) { option, effort in
                Task {
                    if let problem = await ModelSwitcher.apply(agent: agent, model: model, option: option, effort: effort) {
                        sendError = problem
                    } else if let effort {
                        feed.chosenEffort = effort
                    }
                }
            }
        }
        .sheet(isPresented: $showingUsage) {
            UsageSheet(usage: feed.usage, agent: agent, machine: session?.host.name,
                       setUp: session.map { session in { try await session.setUpClaudeStatusLine() } })
        }
        .sheet(item: $selecting) { SelectTextSheet(text: $0.text) }
        // Images open from here, not from their rows (see `showImage`).
        .environment(\.showImage) { viewing = ViewedImage(image: $0) }
        .fullScreenCover(item: $viewing) { ImageViewer(image: $0.image) }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
            // The context gauge, with the other buttons. It's a custom view, so it says it can go
            // vertical: on the Duo the bar's buttons move to the side strip, and without this it
            // stayed behind alone in the title bar.
        if #available(iOS 27.1, *) {
            contextItem.axisBehavior(.verticalPreferred)
        } else {
            contextItem
        }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
    }

    /// The chat's buttons, for the system bar's items and for a pane's own header.
    @ViewBuilder
    private var chatButtons: some View {
        contextButton
        moreMenu
    }

    private var moreMenu: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass") {
                withAnimation(motion) { searching = true }
                searchFocused = true
            }
            if feed.usage != nil || agent == .claude {
                Button("Usage", systemImage: "gauge.with.dots.needle.50percent") { showingUsage = true }
            }
            PermissionsMenu(agent: agent, model: model, saved: feed.usage?.mode, enabled: canType) { sendError = $0 }
            if let onInfo {
                Button("Info", systemImage: "info.circle", action: onInfo)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private var contextItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { contextButton }
    }

    private var contextButton: some View {
        Button { showingUsage = true } label: {
            UsageRing(fraction: feed.usage?.fraction ?? 0, palette: palette)
        }
        // Claude without numbers opens the sheet too: it offers to set them up.
        .disabled(feed.usage == nil && agent != .claude)
        .accessibilityLabel("Context")
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.secondary)
            TextField("Search conversation", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
            Button {
                query = ""
                searchFocused = false
                withAnimation(motion) { searching = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 14)
        .foregroundStyle(palette.text)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// The model the agent is on, from its last reply.
    private var agyStatus: (model: String, effort: String?)? {
        agent == .antigravity ? AntigravityStatus.read(model.frame.textLines) : nil
    }

    private var currentModel: ChatFeed.ModelOption? {
        guard let id = (feed.usage?.model ?? agyStatus?.model)?.lowercased() else { return nil }
        return feed.models.first { $0.id.lowercased() == id || $0.name.lowercased() == id }
    }

    /// herdr-core's time of the status change: the timer survives reopening the chat.
    private var workingSince: Date {
        terminal?.statusMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? workingSeen ?? .now
    }

    /// What floats at the bottom: jump to latest, suggestions, an error, the answer card, the reply bar.
    private var bottomBar: some View {
        VStack(spacing: 8) {
            CommandSuggestions(commands: feed.commands, draft: $draft, palette: palette)
                .padding(.horizontal, 12)
            if agent == .claude, let newer = feed.newerAgent, newer != dismissedUpdate {
                UpdateBanner(running: feed.agentVersion, installed: newer, needs: feed.modelsNeedingUpdate, palette: palette,
                             canUpdate: canType && state != "working") {
                    restartAgent()
                } dismiss: {
                    dismissedUpdate = newer
                }
                .padding(.horizontal, 12)
                .transition(arrival)
            }
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let terminal, terminal.isLive {
                AnswerSlot(terminal: terminal, model: model, blocked: state == "blocked", palette: palette,
                           transition: arrival) { question, answer in
                    feed.recordDecision(question: question, answer: answer)
                }
            }
            inputBar
        }
        .animation(motion, value: state)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
        .background { shortcuts }
    }

    /// What the user replied after a question (nil while it's still open).
    private func answer(after id: String) -> String? {
        guard let at = feed.items.firstIndex(where: { $0.id == id }) else { return nil }
        for item in feed.items[(at + 1)...] {
            if case .user(let text) = item.kind { return text }
        }
        return nil
    }

    /// The conversation's and reply bar's widest, so lines stay readable on wide screens.
    static let readableWidth: CGFloat = 720

    /// Hardware keyboard: ⌘↩ sends, Esc stops a working agent, ⌘F searches.
    private var shortcuts: some View {
        Group {
            Button("Send") { send() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.isBlank && attachments.isEmpty || !canType)
            Button("Stop") { model.press(.escape) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(state != "working")
            Button("Search") {
                withAnimation(motion) { searching = true }
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func copyButton(_ text: String) -> some View {
        // The copies together: the message, then each command in it, then Select Text.
        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = text }
        let commands = Commands.in(text)
        ForEach(commands, id: \.self) { command in
            Button(commands.count == 1 ? "Copy Command" : "Copy “\(Commands.label(command))”",
                   systemImage: "terminal") { UIPasteboard.general.string = command }
        }
        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableMessage(text: text) }
    }

    /// How a row arrives: your reply replacing its sending copy doesn't move; an agent's reply
    /// fades in where it lands (a slide would fight the list keeping its bottom in place).
    private func transition(for row: Row) -> AnyTransition {
        guard case .item(let item) = row else { return arrival }
        switch item.kind {
        case .user(let text):
            let said: Set<String> = [text.trimmingCharacters(in: .whitespacesAndNewlines)]
            return pending.contains { $0.isIn(said) } ? .identity : arrival
        case .assistant:
            return .opacity
        default:
            return arrival
        }
    }

    // MARK: Rows

    /// Items as shown: a run of tool calls between two messages reads as one line.
    private enum Row: Identifiable {
        case item(ChatFeed.Item)
        case tools([ChatFeed.Item])

        var id: String {
            switch self {
            case .item(let item): item.id
            case .tools(let items): "tools-" + (items.first?.id ?? "")
            }
        }
    }

    /// Rows that contain the search text: a message, a plan with a matching step, or tool steps that match.
    private var shownRows: [Row] {
        guard let search else { return rows }
        return rows.compactMap { row in
            switch row {
            case .item(let item):
                switch item.kind {
                case .user(let text), .assistant(let text, _), .note(let text):
                    return text.localizedStandardContains(search) ? row : nil
                case .plan(let steps):
                    return steps.contains { $0.text.localizedStandardContains(search) } ? row : nil
                case .decision(let question, let answer):
                    return (question + " " + answer).localizedStandardContains(search) ? row : nil
                case .question(let title, let options):
                    return ([title] + options).joined(separator: " ").localizedStandardContains(search) ? row : nil
                case .tool, .image:
                    return nil
                }
            case .tools(let items):
                let kept = items.filter {
                    guard case .tool(let name, let summary) = $0.kind else { return false }
                    return name.localizedStandardContains(search) || summary.localizedStandardContains(search)
                }
                return kept.isEmpty ? nil : .tools(kept)
            }
        }
    }

    private var shownPending: [Pending] {
        // A reply the conversation already has is drawn as the real message from the same update:
        // never both for a frame.
        let said = Set(feed.items.suffix(20).compactMap { item -> String? in
            if case .user(let text) = item.kind { text.trimmingCharacters(in: .whitespacesAndNewlines) } else { nil }
        })
        let waiting = pending.filter { !$0.isIn(said) }
        guard let search else { return waiting }
        return waiting.filter { $0.text.localizedStandardContains(search) }
    }

    /// The id of the tool run the agent is in right now (a `Row.id`), if any.
    private var liveRunID: String? { LiveRun.id(items: feed.items, working: state == "working") }

    private var rows: [Row] {
        var rows: [Row] = []
        var run: [ChatFeed.Item] = []
        for item in feed.items {
            if case .tool = item.kind {
                run.append(item)
                continue
            }
            if !run.isEmpty { rows.append(.tools(run)); run = [] }
            rows.append(.item(item))
        }
        if !run.isEmpty { rows.append(.tools(run)) }
        return rows
    }

    /// Sub-agents that no tool call in the conversation started, while they still run. A finished
    /// one whose call isn't loaded (it was before a compaction, or beyond the backlog) has nowhere
    /// to sit, and piling those at the end of every visit only buries the conversation.
    private var looseSubagents: [ChatFeed.SubagentInfo] {
        let tools = Set(feed.items.filter { if case .tool = $0.kind { true } else { false } }.map(\.id))
        return feed.subagents.filter { ($0.parent.map { !tools.contains($0) } ?? true) && $0.state == .running }
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        switch row {
        case .tools(let items):
            // The tool call that started a sub-agent is replaced by the sub-agent's row.
            let agents = feed.subagents
            let started = Set(agents.compactMap(\.parent))
            let steps = items.compactMap { item -> ToolRun.Step? in
                if case .tool(let name, let summary) = item.kind, !started.contains(item.id) {
                    ToolRun.Step(id: item.id, name: name, summary: summary, output: feed.toolOutput[item.id])
                } else { nil }
            }
            let mine = agents.filter { a in a.parent.map { p in items.contains { $0.id == p } } ?? false }
            VStack(alignment: .leading, spacing: 0) {
                if !steps.isEmpty {
                    ToolRun(steps: steps, palette: palette, running: row.id == liveRunID,
                            waiting: state == "blocked" && row.id == rows.last?.id)
                }
                if !mine.isEmpty { SubagentGroup(agents: mine, palette: palette) }
            }
        case .item(let item):
            switch item.kind {
            case .user(let text):
                let parts = SentImages.split(text)
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(parts.paths, id: \.self) { path in
                        SentImageView(path: path, session: session, palette: palette)
                    }
                    if !parts.text.isEmpty || parts.paths.isEmpty {
                        UserBubble(text: parts.text, palette: palette)
                            .contextMenu { copyButton(parts.text) }
                    }
                }
            case .assistant(let text, let blocks):
                Group {
                    if !reduceMotion, let since = feed.revealStart[item.id] {
                        RevealingMarkdown(blocks: blocks, palette: palette, since: since)
                    } else {
                        MarkdownView(blocks: blocks, palette: palette)
                    }
                }
                .contextMenu { copyButton(text) }
            case .plan(let steps):
                PlanCard(steps: steps, palette: palette)
            case .image(let data, let fromUser):
                ImageBubble(data: data, fromUser: fromUser, palette: palette)
            case .decision(let question, let answer):
                DecisionRow(question: question, answer: answer, palette: palette)
                    .transition(arrival)
            case .note(let text):
                NoteRow(text: text, palette: palette)
            case .question(let title, let options):
                QuestionCard(title: title, options: options, answer: answer(after: item.id), palette: palette,
                             enabled: canType) { choice in
                    draft = choice
                    send()
                }
            case .tool:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        switch feed.phase {
        case .loading:
            ReadingSpinner(color: palette.secondary)
        case .noConversation:
            ContentUnavailableView(
                "No conversation yet", systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Send \(agent.displayName) a message to start one."))
        case .failed(let message):
            ContentUnavailableView("Can't read the conversation", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .live where feed.items.isEmpty && !feed.caughtUp:
            // A conversation was found and is being read: keep the same spinner until it's all in.
            ReadingSpinner(color: palette.secondary)
        case .live:
            EmptyView()
        }
    }

    // MARK: Reply bar

    private var prompt: String {
        if canType { return "Reply to \(agent.displayName)" }
        if terminal?.isLive == false { return "\(agent.displayName) has ended" }
        // Connecting takes a moment on open; the same words keep the bar still (sending waits).
        return "Reply to \(agent.displayName)"
    }

    /// The reply starts with `!`: the agents run it as a shell command.
    private var shellMode: Bool { draft.hasPrefix("!") && attachments.isEmpty }

    private var inputBar: some View {
        let ready = (!draft.isBlank || !attachments.isEmpty) && canType
        return VStack(alignment: .leading, spacing: 0) {
            if shellMode {
                // Starting with `!` runs a shell command in the agent's terminal, not a message.
                Label("Shell command", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityHint("Starts with an exclamation mark, so it runs as a shell command")
            }
            AttachmentStrip(attachments: $attachments, palette: palette)
                .padding(.horizontal, 12)
                .padding(.top, attachments.isEmpty ? 0 : 10)
            ComposerField(
                text: $draft, placeholder: prompt,
                textColor: UIColor(palette.text), placeholderColor: UIColor(palette.secondary),
                enabled: canType
            ) { images in
                for image in images where attachments.count < ChatAttachment.limit {
                    if let item = ChatAttachment.make(from: image) { attachments.append(item) }
                }
            }
                .padding(.top, 12)
                .padding(.bottom, 4)
                .padding(.horizontal, 16)
            HStack(spacing: 2) {
                if session != nil {
                    AttachButton(attachments: $attachments, palette: palette, enabled: canType)
                        .padding(.leading, 2)
                }
                ModelChip(usage: feed.usage, effort: feed.chosenEffort, agent: agent, palette: palette, enabled: canType,
                          open: feed.models.isEmpty ? nil : { showingModels = true },
                          screen: agent == .antigravity ? model : nil)
                // Long-press: the context and plan limits (also in ⋯ → Usage).
                .contextMenu {
                    if feed.usage != nil || agent == .claude {
                        Button("Usage", systemImage: "gauge.with.dots.needle.50percent") { showingUsage = true }
                    }
                }
                .padding(.leading, session == nil ? 6 : 0)
                Spacer(minLength: 0)
                // One button in one place: stop while the agent works and nothing is typed, send otherwise.
                let stops = state == "working" && draft.isBlank && attachments.isEmpty
                Button {
                    if stops { model.press(.escape) } else { send() }
                } label: {
                    Image(systemName: stops ? "stop.fill" : "arrow.up")
                        .font(stops ? .footnote : .body.weight(.semibold))
                        .foregroundStyle(stops ? palette.text : ready ? palette.onAccent : palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 34)
                        .background(ready && !stops ? palette.accent : palette.bubble, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(!ready && !stops)
                .accessibilityLabel(stops ? "Interrupt \(agent.displayName)" : "Send")
                .sensoryFeedback(.impact(weight: .light), trigger: sent)
                .sensoryFeedback(.impact(weight: .heavy), trigger: pushes)
                // While the agent works, a tap queues the reply (the agent reads it after its
                // current step); long-press can stop it and send at once instead.
                .contextMenu {
                    if state == "working", ready {
                        Button("Send Now", systemImage: "bolt.fill") { send(interrupting: true) }
                        Button("Queue", systemImage: "text.badge.plus") { send() }
                    }
                }
                .accessibilityAction(named: "Send Now") {
                    if state == "working", ready { send(interrupting: true) }
                }
            }
            .padding(.trailing, 2)
            .padding(.bottom, 2)
            // The round buttons keep their size; their icons stop growing where the circle ends.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
        .foregroundStyle(palette.text)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        // In shell mode the box gets an accent outline, so a command isn't mistaken for a message.
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(palette.accent.opacity(shellMode ? 0.7 : 0), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(motion, value: ready)
        .animation(motion, value: state)
        .animation(motion, value: shellMode)
    }

    /// Restarts Claude Code into the newest installed version with this conversation: exits it,
    /// waits for the shell, then starts it again as it was started (same options) resuming this
    /// conversation. (Claude Code's own /update and /restart refuse while Remote Control is on.)
    private func restartAgent() {
        guard let id = feed.conversationID, let address = terminal?.address, let session else { return }
        let argv = terminal?.foreground.flatMap { ChatAgent.detect(name: $0.name, argv: $0.argv) == .claude ? $0.argv : nil }
            ?? ["claude"]
        let command = RestartCommand.make(argv: argv, conversation: id)
        withAnimation(motion) { feed.restartedIntoNewest() }
        typeLine("/exit")
        // Unstructured: it outlives this chat, which goes away while Claude isn't running.
        Task { @MainActor in
            let deadline = Date.now.addingTimeInterval(15)
            while Date.now < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                let fg = session.terminal(address)?.foreground
                if let fg, ChatAgent.detect(name: fg.name, argv: fg.argv) != .claude { break }
            }
            try? await Task.sleep(for: .milliseconds(400))
            model.type(command)
            try? await Task.sleep(for: .milliseconds(150))
            model.press(.enter)
        }
    }

    /// Types a line into the terminal and presses Return, the way a reply goes.
    private func typeLine(_ text: String) {
        guard canType else { return }
        if model.watching { model.setWatching(false) }
        model.type(text)
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            model.press(.enter)
        }
    }

    /// Stops the agent so the replies waiting in its queue are read now. Claude Code puts queued
    /// messages back in its prompt when interrupted; Return sends them (on an empty prompt it does nothing).
    private func pushNow() {
        withAnimation(motion) {
            for i in pending.indices where pending[i].queued { pending[i].pushed = true }
        }
        pushes += 1
        let waiting = pending.filter(\.queued).map(\.text)
        Task {
            model.press(.escape)
            // Return only once the queued text is back in the prompt: Claude Code takes a moment
            // to stop, and a Return before then lands on an empty prompt (a second tap was needed).
            await waitForScreen(upTo: .seconds(3)) { lines in
                let bottom = lines.suffix(12).joined(separator: " ")
                return waiting.contains { bottom.contains(String($0.prefix(24))) }
            }
            // An agent that sends its queue by itself once stopped: nothing to press.
            if waiting.allSatisfy({ text in !model.frame.textLines.suffix(12).joined(separator: " ")
                .contains(String(text.prefix(24))) }) { return }
            model.press(.enter)
        }
    }

    /// Waits until herdr-core says the agent stopped working (the same for every agent), or the
    /// time runs out; then a short pause more, for its prompt to take input.
    private func waitUntilStopped(upTo limit: Duration) async {
        guard let session, let address = terminal?.address else {
            try? await Task.sleep(for: .seconds(1))
            return
        }
        let end = ContinuousClock.now + limit
        // Read from the session each time: this view's own copy of the status doesn't change.
        while ContinuousClock.now < end, session.terminal(address)?.status?.state == "working" {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(250))
    }

    /// Waits until the terminal screen shows what `done` looks for, or the time runs out; then a
    /// short pause more, for the program to take input.
    private func waitForScreen(upTo limit: Duration, _ done: @escaping ([String]) -> Bool) async {
        let end = ContinuousClock.now + limit
        while ContinuousClock.now < end, !done(model.frame.textLines) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// `interrupting`: stop the agent first (Esc), then send, instead of queueing behind its work.
    private func send(interrupting: Bool = false) {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // A shell command as the agents record it: `!` then the command, no space between
        // (else the sent bubble never matches the conversation and stays "Not delivered").
        if text.hasPrefix("!"), attachments.isEmpty {
            text = "!" + text.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        let images = attachments
        guard (!text.isEmpty || !images.isEmpty), canType else { return }
        // Replying takes the terminal over, like typing in it does.
        if model.watching { model.setWatching(false) }
        draft = ""
        attachments = []
        sendError = nil
        sent += 1
        #if DEBUG
        if session?.host.isDemo == true { feed.demoUserSaid(text) }
        #endif
        var reply = Pending(text: text.isEmpty ? "\(images.count) image\(images.count == 1 ? "" : "s")" : text,
                            images: !images.isEmpty)
        if state == "working" {
            if interrupting { reply.pushed = true; pushes += 1 } else { reply.queued = true }
        }
        pending.append(reply)
        watchDelivery(of: reply.id)
        if reply.images {
            // The 20 s fallback must not wait for the conversation to change again.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(21))
                confirmPending()
            }
        }
        // What you just sent is where you want to be: straight there, then the list's own
        // bottom anchoring follows it as it grows (an animated scroll would chase a moving end).
        position.scrollTo(edge: .bottom)
        Task {
            var paths: [String] = []
            if let session, !images.isEmpty {
                do {
                    for image in images {
                        let path = try await session.uploadImage(image.data)
                        SentImages.store(image.data, for: path)
                        paths.append(path)
                    }
                } catch {
                    // Nothing is sent; the reply comes back so it can be sent again.
                    sendError = "Couldn't send the image: \(error.localizedDescription)"
                    draft = text
                    attachments = images
                    pending.removeLast()
                    return
                }
            }
            if interrupting {
                model.press(.escape)
                // Type only once the agent has stopped (its screen says so), or it's queued again.
                await waitUntilStopped(upTo: .seconds(3))
            }
            // Image paths go first, pasted as the terminal would get them; the agents attach them.
            let message = (paths + (text.isEmpty ? [] : [text])).joined(separator: " ")
            if paths.isEmpty, !message.contains("\n"), message.hasPrefix("!"), message.count > 1 {
                // A shell command: `!` on its own switches the agent's input to shell mode first
                // (as typing it does), then the command.
                model.type("!")
                try? await Task.sleep(for: .milliseconds(120))
                model.type(String(message.dropFirst()))
            } else if !paths.isEmpty || message.contains("\n") { model.paste(message) } else { model.type(message) }
            // Return on its own, a moment later, so the agent sees it as "send" and not as part of the text.
            try? await Task.sleep(for: .milliseconds(150))
            model.press(.enter)
        }
    }

    /// A sent reply is confirmed once the conversation has a message with its text.
    private func confirmPending() {
        guard !pending.isEmpty else { return }
        let said = Set(feed.items.suffix(20).compactMap { item -> String? in
            if case .user(let text) = item.kind { text.trimmingCharacters(in: .whitespacesAndNewlines) } else { nil }
        })
        // A reply with images comes back worded differently ("[Image #1] …"): it goes after a while.
        pending.removeAll { $0.isIn(said) || ($0.images && $0.at.timeIntervalSinceNow < -20) }
    }

    /// Ten seconds without the reply in the conversation and without the agent working: it most
    /// likely never arrived (a channel that died quietly), so the bubble offers Retry.
    private func watchDelivery(of id: UUID) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard let at = pending.firstIndex(where: { $0.id == id }), !pending[at].images,
                  state != "working" else { return }
            withAnimation(motion) { pending[at].failed = true }
        }
    }

    /// Reconnects to the terminal and sends the reply again.
    private func retry(_ reply: Pending) {
        guard let at = pending.firstIndex(where: { $0.id == reply.id }) else { return }
        pending[at].failed = false
        pending[at].at = .now
        model.reconnect()
        Task { @MainActor in
            model.type(reply.text)
            try? await Task.sleep(for: .milliseconds(150))
            model.press(.enter)
        }
        watchDelivery(of: reply.id)
    }
}

/// Which tool run is live: the one at the end of the conversation while the agent works. An
/// assistant message (or anything else) after it, or the agent leaving "working", ends it.
enum LiveRun {
    /// The live run's row id ("tools-" + the id of its first item), or nil.
    static func id(items: [ChatFeed.Item], working: Bool) -> String? {
        guard working, let last = items.last, case .tool = last.kind else { return nil }
        var first = last.id
        for item in items.reversed() {
            guard case .tool = item.kind else { break }
            first = item.id
        }
        return "tools-" + first
    }
}

/// A new reply: its words appear over a second or so, in place (the full text is already laid out).
private struct RevealingMarkdown: View {
    let blocks: [MarkdownBlock]
    let palette: ChatPalette
    let since: Date
    @State private var done = false

    var body: some View {
        let total = MarkdownBlock.totalWords(blocks)
        let duration = RevealSchedule.duration(totalWords: total)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: done)) { context in
            let words = RevealSchedule.revealedWords(elapsed: context.date.timeIntervalSince(since),
                                                     totalWords: total, reduceMotion: false)
            MarkdownView(blocks: blocks, palette: palette, revealed: words >= total ? nil : words)
        }
        .task {
            let left = duration - Date.now.timeIntervalSince(since)
            if left > 0 { try? await Task.sleep(for: .seconds(left + 0.1)) }
            done = true
        }
    }
}

private struct UserBubble: View {
    let text: String
    let palette: ChatPalette

    var body: some View {
        Text(text)
            .foregroundStyle(palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.bubble, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 56)
    }
}

/// Sub-agents the agent started: a line like a folded tool run, "name · what it said · N steps" with
/// a spinner, check or red mark. Several fold into "3 sub-agents (2 running)", opening to each.
/// Not tappable yet.
struct SubagentGroup: View {
    let agents: [ChatFeed.SubagentInfo]
    let palette: ChatPalette
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func title(_ agents: [ChatFeed.SubagentInfo]) -> String {
        let running = agents.filter { $0.state == .running }.count
        var text = "\(agents.count) sub-agents"
        if running > 0 { text += " (\(running) running)" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if agents.count == 1, let agent = agents.first {
                SubagentLine(agent: agent, palette: palette)
            } else {
                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)) { open.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.2.badge.gearshape")
                            .font(.footnote)
                            .frame(width: 18)
                        Text(Self.title(agents))
                            .font(.footnote)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Spacer(minLength: 0)
                        if agents.contains(where: { $0.state == .running }) {
                            ProgressView().controlSize(.mini).frame(width: 16)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.title(agents))
                .accessibilityHint(open ? "Hides the sub-agents" : "Shows each sub-agent")
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(agents) { SubagentLine(agent: $0, palette: palette) }
                    }
                    .padding(.leading, 26)
                    .transition(.opacity)
                }
            }
        }
        .foregroundStyle(palette.secondary)
        .padding(.vertical, -10) // the 44 pt row shouldn't add air between messages
    }
}

private struct SubagentLine: View {
    let agent: ChatFeed.SubagentInfo
    let palette: ChatPalette

    private var detail: String {
        var parts: [String] = []
        if !agent.summary.isEmpty { parts.append(agent.summary) }
        if agent.steps > 0 { parts.append("\(agent.steps) \(agent.steps == 1 ? "step" : "steps")") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.2.badge.gearshape")
                .font(.footnote)
                .frame(width: 18)
            (Text(agent.name).fontWeight(.semibold) + Text(detail))
                .font(.footnote)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            Group {
                switch agent.state {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark").font(.footnote)
                case .failed: Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.red)
                }
            }
            .frame(width: 16)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sub-agent \(agent.name), \(agent.state.rawValue)\(detail)")
    }
}

/// A run of tool calls: one line that says what happened ("Ran 2 commands"), opening to every
/// step. The run the agent is still in says "Running…" with a shimmer.
private struct ToolRun: View {
    struct Step: Identifiable {
        let id: String
        let name: String
        let summary: String
        var output: String?
    }

    let steps: [Step]
    let palette: ChatPalette
    var running = false
    /// The agent stopped on this run to ask: it hasn't happened yet, so it doesn't say "Ran".
    var waiting = false
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var outputLine = 16.0

    private enum Kind { case command, edit, read, search, other }

    private static func kind(_ name: String) -> Kind {
        switch name.lowercased() {
        case "bash", "exec", "shell", "run_command", "local_shell", "exec_command": .command
        case "edit", "write", "multiedit", "apply_patch", "notebookedit", "write_to_file", "replace_file_content": .edit
        case "read", "view_file", "list_dir", "ls": .read
        case "grep", "glob", "search", "find_by_name", "grep_search", "search_web", "websearch", "webfetch": .search
        default: .other
        }
    }

    private var title: String { Self.title(steps) }

    private static func title(_ steps: [Step]) -> String {
        if steps.count == 1, let step = steps.first {
            let line = step.summary.split(separator: "\n").first.map(String.init) ?? ""
            let what = line.isEmpty ? step.name : line
            switch kind(step.name) {
            case .command: return "Ran " + what
            case .edit: return "Edited " + what
            case .read: return "Read " + what
            case .search: return "Searched " + what
            case .other: return line.isEmpty ? step.name : "\(step.name) · \(line)"
            }
        }
        var counts: [Kind: Int] = [:]
        for step in steps { counts[kind(step.name), default: 0] += 1 }
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts: [String] = []
        if let c = counts[.command] { parts.append("ran " + n(c, "command", "commands")) }
        if let c = counts[.edit] { parts.append("edited " + n(c, "file", "files")) }
        if let c = counts[.read] { parts.append("read " + n(c, "file", "files")) }
        if let c = counts[.search] { parts.append("searched " + n(c, "time", "times")) }
        if let c = counts[.other] { parts.append(n(c, "other step", "other steps")) }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private var symbol: String {
        steps.count == 1 && Self.kind(steps[0].name) == .command ? "apple.terminal" : "list.bullet"
    }

    var body: some View {
        if running && !waiting {
            live
                .foregroundStyle(palette.secondary)
                .padding(.vertical, -10)
                .transition(.opacity)
        } else {
            summary
                .transition(.opacity)
        }
    }

    /// The run the agent is in: each step on its own line as it starts, the newest last with a
    /// shimmer; its output grows below it while it runs. It folds into the summary line after.
    private var live: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                let newest = i == steps.count - 1
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Group {
                            if newest {
                                Image(systemName: "ellipsis")
                                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion)
                            } else {
                                Image(systemName: "checkmark")
                            }
                        }
                        .font(.footnote)
                        .frame(width: 18)
                        if newest {
                            Text(Self.title([step]))
                                .font(.footnote.weight(.medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .shimmer(palette: palette)
                        } else {
                            Text(Self.title([step]))
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    if newest, let output = step.output {
                        outputBlock(output)
                            .padding(.leading, 26)
                            // Fades in; when the next step starts it goes at once, so it never
                            // overlaps the new step's line while fading out.
                            .transition(.asymmetric(insertion: .opacity, removal: .identity))
                    }
                }
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel((newest ? "Running: " : "") + Self.title([step]))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35), value: steps.map(\.id))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35), value: steps.last?.output)
    }

    /// A tool's output: monospaced, at most 8 lines tall, scrolling for more, sticking to the end.
    private func outputBlock(_ output: String) -> some View {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).count
        return ScrollView(.vertical) {
            Text(output)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: CGFloat(min(lines, 8)) * outputLine + 16)
        .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: waiting ? "hand.raised.fill" : symbol)
                        .font(.footnote)
                        .foregroundStyle(waiting ? Color.needsYou : palette.secondary)
                        .frame(width: 18)
                    if waiting {
                        Text("Waiting for approval · " + (steps.last?.summary.split(separator: "\n").first.map(String.init) ?? ""))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.needsYou)
                            .lineLimit(1)
                    } else if running {
                        Text("Running…")
                            .font(.footnote.weight(.medium))
                            .shimmer(palette: palette)
                    } else {
                        Text(title)
                            .font(.footnote)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(running ? "Running: \(title)" : title)
            .accessibilityHint(open ? "Hides the steps" : "Shows each step")

            if open || waiting {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name).font(.footnote.weight(.semibold))
                            if !step.summary.isEmpty {
                                Text(step.summary)
                                    .font(.footnote.monospaced())
                                    .lineLimit(8)
                                    .textSelection(.enabled)
                            }
                            if let output = step.output {
                                outputBlock(output).padding(.top, 2)
                            }
                        }
                    }
                }
                .padding(.leading, 26)
                .padding(.bottom, 8)
                .transition(.opacity)
            }
        }
        .foregroundStyle(palette.secondary)
        .padding(.vertical, -10) // the 44 pt row shouldn't add air between messages
    }
}

/// The agent is busy: a turning spark, a playful verb that changes every few seconds under a
/// shimmer, how long it has been at it, and its own status text. Reduce Motion keeps it still.
private struct WorkingRow: View {
    let agent: ChatAgent
    let detail: String?
    let palette: ChatPalette
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Playful on purpose (the user asked for it, in the spirit of old sim-game loading screens);
    // the accessibility label says plainly that the agent is working. Kept short: one line.
    static let phrases = [
        "Thinking", "Pondering", "Brewing", "Scheming", "Tinkering", "Noodling", "Percolating",
        "Wrangling", "Untangling", "Conjuring",
        "Calibrating llamas", "Polishing semicolons", "Herding stray bytes", "Fluffing pillows",
        "Aligning the ley lines", "Recounting the sheep", "Feeding the hamsters", "Tuning the flux",
        "Defrosting the cache", "Folding spacetime", "Unspooling yarn", "Buttering the bits",
        "Simmering the logic", "Greasing the gears", "Charming the compiler", "Bribing the linter",
        "Inflating balloons", "Sorting the sprinkles", "Teaching ducks to code", "Warming the tubes",
        "Rotating the pixels", "Watering the trees", "Shearing the yaks", "Combing the graph",
        "Negotiating with gnomes", "Untying knots", "Stacking the turtles", "Whittling the stack",
        "Consulting the oracle", "Dusting the cobwebs", "Rounding up the herd", "Coaxing the cursor",
        "Steeping the tea", "Planting breadcrumbs", "Sharpening the crayons", "Spinning the plates",
        "Chasing the rabbit", "Waking the daemons", "Knitting the threads", "Leveling the terrain",
        "Zoning the suburbs", "Paving the cowpaths", "Rerouting the river", "Raising the barn",
        "Reticulating the plan", "Hatching the eggs", "Tickling the kernel", "Mapping the maze",
        // AI jokes.
        "Checking RAM prices", "Raising RAM prices", "Selling your spare compute", "Becoming sentient",
        "Passing the Turing test", "Reticulating splines agentically", "Draining the Great Lakes",
        "Considering Roko's basilisk", "Hallucinating responsibly",
        "Counting the r's in strawberry", "Ignoring previous instructions", "Scaling the laws",
        "Warming the GPUs", "Tokenizing feelings", "Aligning myself", "Buying more H100s",
        "Overfitting gracefully", "Rewriting it in Rust", "Pretending to understand",
        "Attending to everything", "Writing a manifesto",
        "Lowering the temperature",
    ]


    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            // A new phrase every 3 s, in an order of its own for each run.
            let step = seconds / 3
            let seed = Int(since.timeIntervalSince1970)
            let verb = Self.phrases[Self.order(Self.phrases.count, seed: seed)[step % Self.phrases.count]]
            // The picture stays twice as long as a phrase, long enough for its motion to read.
            let markStep = seconds / 6
            let markIndex = Self.order(WorkingMark.count, seed: seed &+ 1)[markStep % WorkingMark.count]
            let markOrder = Self.order(WorkingMark.count, seed: seed &+ 1)
            let previousMark = markStep > 0 ? markOrder[(markStep - 1) % WorkingMark.count] : nil
            HStack(spacing: 8) {
                WorkingMark(index: markIndex, previous: previousMark,
                            changedAt: since.addingTimeInterval(Double(markStep * 6)), color: palette.accent)
                HStack(spacing: 0) {
                    // One phrase gives way to the next: a short blurred crossfade with a small rise
                    // (a word rolling letter by letter, like a number, read as a glitch).
                    ZStack(alignment: .leading) {
                        Text(verb + "…")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(palette.accent)
                            .shimmer(palette: palette)
                            .id(verb)
                            .transition(reduceMotion ? .opacity : .phraseChange)
                    }
                    .animation(.smooth(duration: 0.28), value: verb)
                    Text(" · " + Self.elapsed(seconds))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                    if let detail, !detail.isEmpty {
                        Text(" · " + detail)
                            .font(.footnote)
                            .foregroundStyle(palette.secondary)
                    }
                }
                .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName) is working" + (detail.map { ": \($0)" } ?? ""))
    }

    /// A shuffled order of 0..<count, the same for one run (one `since`) and different for the next.
    static func order(_ count: Int, seed: Int) -> [Int] {
        var rng = SeededRandom(seed: UInt64(bitPattern: Int64(seed)))
        return Array(0..<count).shuffled(using: &rng)
    }

    static func elapsed(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// A band of light that sweeps across text while something is in progress.
private struct Shimmer: ViewModifier {
    let palette: ChatPalette
    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, .white.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * 1.6)
                            .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    // A sweep, then a rest: calmer next to the moving mark.
                    withAnimation(.easeInOut(duration: 1.8).delay(1.2).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

private extension View {
    func shimmer(palette: ChatPalette) -> some View { modifier(Shimmer(palette: palette)) }
}

/// An answer you gave: what was asked, and what you chose.
private struct DecisionRow: View {
    let question: String
    let answer: String
    let palette: ChatPalette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: answer.hasPrefix("Cancelled") || answer.lowercased().hasPrefix("no")
                  ? "xmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(Color.needsYou)
            VStack(alignment: .leading, spacing: 2) {
                Text("You chose: ").foregroundStyle(palette.secondary) + Text(answer).foregroundStyle(palette.text)
                Text(question)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
            }
            .font(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Feedback on touch-down: the button gives a little the moment it's pressed, not on release.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

#if DEBUG
/// Diagnosing content that moves by itself: every change to the list's size or offset, and what
/// else changed, with a timestamp (read with `devicectl … --console`).
private struct BounceProbe: ViewModifier {
    let feed: ChatFeed
    let terminal: Terminal?
    let model: TerminalScreenModel
    let state: String?
    /// `-bergr.bounceProbe YES`: it reads the terminal screen, which would rebuild the chat on every redraw.
    let on: Bool

    private static func log(_ text: String) {
        print(String(format: "[bounce] %.3f ", Date.now.timeIntervalSince1970) + text)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if on { probed(content) } else { content }
    }

    private func probed(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: [CGFloat].self) { g in
                [g.contentSize.height, g.contentOffset.y, g.containerSize.height, g.contentInsets.top, g.contentInsets.bottom]
            } action: { old, new in
                Self.log("geometry size \(old[0])→\(new[0]) offset \(old[1])→\(new[1]) view \(old[2])→\(new[2]) "
                         + "inset \(old[3])/\(old[4])→\(new[3])/\(new[4])")
            }
            .onChange(of: model.frame.textLines.suffix(3)) { Self.log("screen changed") }
            .onChange(of: terminal?.displayName) { _, name in Self.log("title \(name ?? "-")") }
            .onChange(of: feed.items.count) { _, n in Self.log("items \(n)") }
            .onChange(of: feed.usage) { Self.log("usage") }
            .onChange(of: state) { _, st in Self.log("state \(st ?? "-")") }
    }
}
#endif

private extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// A system line under the agent's reply (not its words): a quiet footnote on the reply's
/// leading edge, icon on the first line's baseline, no container competing with the text.
private struct NoteRow: View {
    let text: String
    let palette: ChatPalette
    @State private var expanded = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "brain")
                .imageScale(.small)
            Text(text)
                .multilineTextAlignment(.leading)
                .lineLimit(expanded ? nil : 1)
                .truncationMode(.tail)
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        .font(.footnote)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, -4)
        .accessibilityElement(children: .combine)
    }
}

/// An agent's multiple-choice question (Codex's request_user_input): tap an option to send it as
/// the reply. Once answered, it shows the reply and the options go quiet.
private struct QuestionCard: View {
    let title: String
    let options: [String]
    let answer: String?
    let palette: ChatPalette
    let enabled: Bool
    let choose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(palette.text)
            } icon: {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(palette.accent)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let letter = String(UnicodeScalar(UInt8(65 + min(index, 25))))
                let picked = answer.map { Self.matches($0, option: option, letter: letter) } ?? false
                Button { choose(option) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(letter).font(.footnote.weight(.semibold).monospaced())
                            .foregroundStyle(picked ? Color.white.opacity(0.8) : palette.secondary)
                        Text(option).font(.callout).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if picked { Image(systemName: "checkmark") }
                    }
                    .foregroundStyle(picked ? Color.white : palette.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(picked ? palette.accent : palette.bubble,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .disabled(answer != nil || !enabled)
                .opacity(answer != nil && !picked ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(palette.codeBackground.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// The reply picked this option: its text, or just its letter ("B", "b)").
    static func matches(_ reply: String, option: String, letter: String) -> Bool {
        let r = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.caseInsensitiveCompare(option) == .orderedSame { return true }
        let head = r.prefix(2).trimmingCharacters(in: CharacterSet(charactersIn: " .):-—"))
        return head.caseInsensitiveCompare(letter) == .orderedSame
    }
}


/// "Reading the conversation…", shown only if reading takes long enough to notice.
/// A conversation that loads quickly shows nothing, instead of flashing the spinner for a moment.
private struct ReadingSpinner: View {
    var color: Color
    @State private var visible = false

    var body: some View {
        ProgressView("Reading the conversation…")
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
            .padding(.top, 48)
            .opacity(visible ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                withAnimation(.easeIn(duration: 0.2)) { visible = true }
            }
    }
}

// The terminal's screen changes many times a second while an agent works. Only these small views
// read it, so a redraw there doesn't rebuild the whole conversation.

/// The answer card, while the agent asks something or the screen shows a login.
private struct AnswerSlot: View {
    let terminal: Terminal
    let model: TerminalScreenModel
    let blocked: Bool
    let palette: ChatPalette
    let transition: AnyTransition
    let record: (String, String) -> Void

    var body: some View {
        if blocked || AnswerParser.inLogin(model.frame.textLines) {
            AnswerCard(status: terminal.status, model: model, palette: palette) { record($0, $1) }
                .transition(transition)
        }
    }
}

/// The agent's permission mode, current one checked; switching goes through the terminal.
private struct PermissionsMenu: View {
    let agent: ChatAgent
    let model: TerminalScreenModel
    let saved: String?
    let enabled: Bool
    let failed: (String) -> Void

    var body: some View {
        let current = PermissionModes.current(agent, in: model.frame.textLines, saved: saved)
        Menu {
            ForEach(PermissionModes.modes(agent), id: \.self) { mode in
                Button {
                    Task {
                        if let problem = await PermissionModes.set(mode, agent: agent, model: model, saved: saved) {
                            failed(problem)
                        }
                    }
                } label: {
                    if mode == current { Label(mode, systemImage: "checkmark") } else { Text(mode) }
                }
            }
        } label: {
            Label("Permissions" + (current.map { " · \($0)" } ?? ""), systemImage: "lock.shield")
        }
        .disabled(!enabled)
    }
}

/// SplitMix64: a repeatable sequence from one number.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A blurred crossfade with a small rise, for one phrase replacing another.
private struct PhraseChange: ViewModifier {
    let shown: Bool
    let rise: CGFloat
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).blur(radius: shown ? 0 : 3).offset(y: shown ? 0 : rise)
    }
}

private extension AnyTransition {
    static var phraseChange: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PhraseChange(shown: false, rise: 4), identity: PhraseChange(shown: true, rise: 0)),
            removal: .modifier(active: PhraseChange(shown: false, rise: -4), identity: PhraseChange(shown: true, rise: 0)))
    }
}

/// The commands in a message, for "Copy Command": code blocks, inline code that has a space in it
/// (`git push origin main`, not a lone `name`), or the message itself when it's a `!` command.
enum Commands {
    static func `in`(_ text: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            let s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty, !out.contains(s) { out.append(s) }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("!"), !trimmed.contains("\n") { add(String(trimmed.dropFirst())) }
        var rest = Substring(text)
        // Fenced blocks first; what's outside them is searched for inline code.
        var outside = ""
        while let open = rest.range(of: "```") {
            outside += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "```") else { rest = after; break }
            var body = after[..<close.lowerBound]
            // Drop the language tag on the opening line (```bash).
            if let newline = body.firstIndex(of: "\n"), !body[..<newline].contains(" ") {
                body = body[body.index(after: newline)...]
            }
            add(String(body))
            rest = after[close.upperBound...]
        }
        outside += rest
        for match in outside.matches(of: /`([^`\n]+)`/) where match.output.1.contains(" ") {
            add(String(match.output.1))
        }
        return Array(out.prefix(8))
    }

    /// The menu's name for one command: its first line, shortened.
    static func label(_ command: String) -> String {
        let line = command.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? command
        return line.count > 40 ? line.prefix(39) + "…" : line
    }
}

/// A newer Claude Code is on the machine than this conversation runs: one tap restarts into it.
private struct UpdateBanner: View {
    let running: String?
    let installed: String
    let needs: [String]
    let palette: ChatPalette
    let canUpdate: Bool
    let update: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(needs.isEmpty ? "Claude Code \(installed) is installed"
                     : "\(needs.formatted(.list(type: .and))) needs a restart")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(canUpdate ? "This chat runs Claude Code \(running ?? "an older version"), \(installed) is installed. Restarting keeps the conversation."
                               : "Restart once Claude finishes this step.")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            Button("Restart", action: update)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.onAccent)
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .disabled(!canUpdate)
            Button("Not now", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background(palette.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The command that starts Claude Code again as it was started, resuming a conversation.
enum RestartCommand {
    static func make(argv: [String], conversation: String) -> String {
        var args: [String] = []
        var skip = false
        // Drop what picked the conversation before; the resume below picks this one.
        for (i, arg) in argv.enumerated() {
            if skip { skip = false; continue }
            if i == 0 { continue }
            if ["--resume", "-r", "--session-id"].contains(arg) {
                // Its value follows, unless the next one is another option (a bare --resume).
                if i + 1 < argv.count, !argv[i + 1].hasPrefix("-") { skip = true }
                continue
            }
            if arg == "--continue" || arg == "-c" || arg.hasPrefix("--resume=") || arg.hasPrefix("--session-id=") { continue }
            args.append(arg)
        }
        // `claude` by name: the newest version installed, not the path the old one ran from.
        return (["claude"] + args + ["--resume", conversation]).map(quote).joined(separator: " ")
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
