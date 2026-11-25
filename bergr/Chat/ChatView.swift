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
    @State private var closingMenu = false
    /// Sent replies, shown at once and until the agent's conversation has them.
    @State private var outbox = ReplyOutbox()
    @State private var sent = 0
    /// Each Send Now: a firmer tap than a send, felt as stopping the agent.
    @State private var pushes = 0
    @State private var showingUsage = false
    @State private var showingChanges = false
    @State private var openedFile: FileRef?
    @State private var previewing: PreviewItem?
    @State private var lifecycle = AgentLifecycle()
    @State private var choosingMode = false
    @State private var selecting: SelectableMessage?
    @State private var viewing: ViewedImage?
    @State private var imageOpener = ImageOpener()
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
    @State private var scroll = ScrollState()
    /// The rows drawn, with what each last showed: a row is built again only when that changed.
    @State private var rowStore = RowStore()
    /// How many rows to draw. The list isn't lazy, so a long conversation drawn whole is slow to
    /// open and to scroll; the latest rows show, earlier ones a tap away. Search looks at all.
    @State private var rowLimit = Self.rowPage
    /// A sideways drag's pull, which shows the messages' times (iOS).
    /// The pending save of the reply being written (see `.onChange(of: draft)`).
    @State private var draftSave: Task<Void, Never>?
    @State private var timeReveal = MessageTimeReveal.Pull()
    // Rows shown at once ("Show earlier" adds more). Fewer on the Mac, where a wide window lays out
    // long rows and every one is measured.
    #if os(macOS)
    private static let rowPage = 40
    #else
    private static let rowPage = 150
    #endif
    /// Scrolled well up from the latest message: a button brings it back.
    @State private var awayFromLatest = false
    /// Stops the chat following its own height when that height keeps flipping (see BounceGuard).
    @State private var bounce = BounceGuard()
    /// The connection bar, once the connection has been down a moment (see the task that sets it).
    @State private var connectionBarShown = false
    #if os(macOS)
    @State private var scrollControl = ChatScrollControl()
    /// The heights of the header and the reply bar over the table, in whole points.
    @State private var macBars = (top: CGFloat(0), bottom: CGFloat(0))
    #else
    private var macBars: (top: CGFloat, bottom: CGFloat) {
        get { (0, 0) }
        nonmutating set {}
    }
    #endif
    /// Messages in the chat when you scrolled away from the latest: the ones after it are new.
    @State private var seenMessages = 0
    /// Options picked on Claude's question cards, until the conversation records the answers.
    @State private var questionPicks: [String: String] = [:]
    /// The next send goes out as a new message even while Codex has a question open.
    @State private var sendAsNewMessage = false
    @State private var questionSending: Set<String> = []
    /// Blocked calls being approved from their card (until the retry shows up).
    @State private var blockedSending: Set<String> = []
    /// The search field at the top shows while searching; closing it clears the search.
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// The search field's text; while it has any, only the matching rows show.
    @State private var query = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(KeyLibrary.self) private var keys
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var palette: ChatPalette { .of(colorScheme) }

    /// The agent's queue as its transcript records it, less what our own replies already show.
    private func othersQueued(_ ours: [ReplyDelivery]) -> [String] {
        let fromTerminal = agent == .codex
        func comparable(_ text: String) -> String {
            if fromTerminal { return text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var mine = ours.map { reply in
            comparable(fromTerminal && reply.payload.hasImages && !reply.imagePaths.isEmpty
                       ? (reply.imagePaths + [reply.payload.typed]).joined(separator: " ") : reply.text)
        }
        let queued = fromTerminal ? model.codexQueuedInputs : feed.queued
        return queued.filter { text in
            let t = comparable(text)
            // Ours with an image comes back with the image's path in front: the words end it.
            if let i = mine.firstIndex(where: { $0 == t || (!fromTerminal && !$0.isEmpty && t.hasSuffix($0)) }) {
                mine.remove(at: i)
                return false
            }
            return true
        }
    }
    private var draftKey: String? {
        guard let session, let address = terminal?.address else { return nil }
        return "\(session.host.id.uuidString)|\(address)"
    }
    private var state: String? {
        if feed.demoWorking { return "working" }
        #if DEBUG
        if previewWorking { return "working" }
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
        #if DEBUG
        let _ = RenderProbe.hit("ChatView")
        #endif
        conversationLayer
        // Over the conversation, not in the bar below it: showing it mustn't move the list (which
        // would change the distance to the bottom and hide it again, over and over).
        .overlay(alignment: .bottomTrailing) { jumpLayer }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        // A reply being written stays with its agent: switching away and back finds it again.
        .onChange(of: draftKey, initial: true) { old, key in
            if old != key, draftSave != nil { draftSave?.cancel(); draftSave = nil; ReplyDrafts.set(draft, for: old) }
            draft = ReplyDrafts.text(for: key)
        }
        // Saved once typing pauses, not per key: each save changed UserDefaults, which redrew every
        // view reading @AppStorage (the whole agents list on the Mac), and typing lagged.
        .onChange(of: draft) { _, text in
            let key = draftKey
            draftSave?.cancel()
            draftSave = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                draftSave = nil
                ReplyDrafts.set(text, for: key)
            }
        }
        // A draft changed from elsewhere (a Shortcut, a notification reply that couldn't be typed).
        .onReceive(NotificationCenter.default.publisher(for: ReplyDrafts.changed)) { note in
            guard let key = draftKey, note.userInfo?["agent"] as? String == key else { return }
            let text = ReplyDrafts.text(for: key)
            if text != draft { draft = text }
        }
        // Where the conversation meets the floating bars, it softens under them instead of a hard cut.
        #if os(iOS)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        #else
        .scrollEdgeEffectStyle(.hard, for: .top)
        // None below: the Mac draws the edge as a lighter band across the whole window behind the
        // reply bar, which floats on its own.
        .scrollEdgeEffectHidden(true, for: .bottom)
        #endif
        #if os(macOS)
        // An empty chat's message in the middle of the window; in the list it sat at the bottom,
        // where the list's anchoring holds the newest message.
        .overlay { placeholderLayer }
        #endif
        // A problem is felt as well as read; a change that went through is felt as done.
        .sensoryFeedback(.error, trigger: sendError) { _, new in new != nil }
        // Watching the feed in a view of its own: reading `feed.items` here would run the
        // chat's body on every streamed token.
        .background(watcherLayer)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let pane { PaneHeader(chrome: pane, backdrop: palette.background) { chatButtons } }
                if let session, connectionBarShown, session.state != .connected, !session.host.isDemo {
                    ConnectionBar(session: session, text: palette.text, secondary: palette.secondary,
                                  background: palette.bubble) { session.retry(keys: keys) }
                        .transition(.opacity)
                }
                if searching { searchBar.transition(.opacity) }
            }
            .macBarHeight { macBars.top = $0 }
        }
        // The reply bar floats over the conversation, which scrolls on under it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar
                .macBarHeight { macBars.bottom = $0 }
        }
        .background(palette.background)
        // A reconnect that's over in a moment (the connection dropped and came straight back)
        // doesn't flash the bar: it shows after 1.5 s without a connection.
        .task(id: session.map { $0.state != .connected } ?? false) {
            guard let session, session.state != .connected else { connectionBarShown = false; return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { withAnimation(motion) { connectionBarShown = true } }
        }
        .onDisappear {
            if draftSave != nil { draftSave?.cancel(); draftSave = nil; ReplyDrafts.set(draft, for: draftKey) }
            outbox.draftKey = draftKey
            let address = terminal?.address
            let keepPending = agent == .codex && session != nil && address != nil
            let pending = outbox.cancelAll(keepingSubmitted: keepPending, items: feed.items)
            if keepPending, let address {
                session?.rememberCodexReplies(pending, address: address, conversation: feed.conversationID)
            }
            // Undelivered replies went back into the draft: take it, so a later edit here keeps them.
            draft = ReplyDrafts.text(for: draftKey)
        }
        // The store keeps this view for building rows: let go of it with the chat (and take it
        // back when the chat shows again without having been rebuilt).
        .onAppear {
            rowStore.chat = self
            if agent == .codex, let session, let address = terminal?.address {
                let pending = session.takeCodexReplies(address: address, conversation: feed.conversationID)
                outbox.restorePending(pending, items: feed.items)
            }
        }
        .onDisappear { rowStore.chat = nil }
        #if os(iOS)
        // `-bergr.demoAttach YES` (screenshots): the demo's Codex question has a scanned sketch attached.
        .task {
            guard session?.host.isDemo == true, terminal?.address == DemoBeat.cacheAgent, attachments.isEmpty,
                  UserDefaults.standard.bool(forKey: "bergr.demoAttach"),
                  let sketch = ChatAttachment.make(from: DemoChat.sketch()) else { return }
            attachments = [sketch]
        }
        #endif
        .onChange(of: state, initial: true) { _, now in workingSeen = now == "working" ? (workingSeen ?? .now) : nil }
        .toolbar { if pane == nil { chatToolbar } }
        .sheet(isPresented: $showingModels) {
            ModelSheet(models: feed.models, current: currentModel,
                       effort: liveModelStatus?.effort ?? feed.usage?.effort ?? feed.chosenEffort) { option, effort in
                Task {
                    if let problem = await ModelSwitcher.apply(agent: agent, model: model, option: option, effort: effort) {
                        sendError = problem
                    } else if let effort {
                        feed.chosenEffort = effort
                    }
                }
            }
        }
        .sheet(isPresented: $showingChanges) {
            ChangesSheet(session: session, folder: ChangesSummary.workFolder(in: feed.items, cwd: feed.agentFolder ?? terminal?.cwd), address: terminal?.address, items: feed.items, toolOutput: feed.toolOutput)
        }
        .sheet(isPresented: $showingUsage) {
            UsageSheet(usage: feed.usage, agent: agent, machine: session?.host.name,
                       setUp: session.map { session in { try await session.setUpClaudeStatusLine() } })
        }
        #if os(iOS)
        .sheet(item: $selecting) { SelectTextSheet(text: $0.text) }
        #endif
        // File paths in messages and tool rows open the file viewer.
        .environment(\.openURL, OpenURLAction { url in
            // Pages on the agent's machine open in the preview, through the SSH connection.
            if let local = LocalWebAddress(url: url), session?.host.isDemo != true {
                previewing = PreviewItem(address: local)
                return .handled
            }
            guard let ref = FileRef(url: url) else { return .systemAction }
            openedFile = ref
            return .handled
        })
        .sheet(item: $openedFile) { ref in
            FileViewerSheet(ref: ref, cwd: terminal?.cwd ?? "", session: session) { path in
                draft += (draft.isEmpty || draft.hasSuffix(" ") ? "" : " ") + path + " "
            }
        }
        .sheet(item: $previewing) { LocalPreviewSheet(address: $0.address, session: session) }
        // Images open from here, not from their rows (see `showImage`).
        .environment(\.showImage, imageOpener.action($viewing))
        .platformCover(item: $viewing) { ImageViewer(image: $0.image) }
    }

    /// To the latest message, with the count of those that arrived meanwhile (read in a view of
    /// its own: counting reads the whole feed).
    @ViewBuilder
    private var jumpButton: some View {
            let unseen = max(messageCount - seenMessages, 0)
            Button {
                scrollToLatest(animated: true)
            } label: {
                HStack(spacing: 6) {
                    if unseen > 0 {
                        Text("\(unseen) new")
                            .font(.subheadline.weight(.semibold))
                            .contentTransition(.numericText())
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                    }
                    Image(systemName: "arrow.down")
                        .font(.body.weight(.semibold))
                }
                .foregroundStyle(palette.text)
                .padding(.horizontal, unseen > 0 ? 14 : 0)
                .frame(minWidth: 40, minHeight: 40)
                .glassEffect(.regular, in: Capsule())
                .frame(minWidth: PlatformMetrics.controlHeight, minHeight: PlatformMetrics.controlHeight)
                .contentShape(Capsule())
                .animation(motion, value: unseen)
            }
            .macPlainButton()
            .accessibilityLabel(unseen > 0 ? "\(unseen) new message\(unseen == 1 ? "" : "s"), jump to latest" : "Jump to latest")
            .padding(.trailing, 16)
            .padding(.bottom, 8)
    }

    /// The conversation reads the feed in a view of its own: a streamed token runs that, not the
    /// whole chat (its bars, toolbar and the window's layout). The scroll view and its scroll
    /// modifiers are inside it, so they stay on the ScrollView itself.
    private var conversationLayer: some View { Isolated { conversationContent() } }
    private var watcherLayer: some View { Isolated { feedWatcher } }
    @ViewBuilder private var placeholderLayer: some View {
        if search == nil { Isolated { placeholder } }
    }
    @ViewBuilder private var jumpLayer: some View {
        if awayFromLatest {
            Isolated { jumpButton }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
        }
    }

    private var feedWatcher: some View {
        let lastID: String? = feed.items.last?.id
        return Color.clear
            .sensoryFeedback(.success, trigger: lastID) { _, _ in
                if case .decision? = feed.items.last?.kind { return true } else { return false }
            }
            .onChange(of: feed.items) { outbox.feedChanged(feed.items) }
    }

    private func conversationContent() -> some View {
        let allRows = rows
        let all = shownRows(allRows)
        let state = self.state
        let canType = self.canType
        // Running ones show at the bottom, under the working line; finished ones stay with the step that started them.
        let tools = ToolContext(liveRunID: liveRunID, agents: feed.subagents.filter { $0.state != .running },
                                lastRowID: allRows.last?.id)
        let loose = search == nil ? looseSubagents : []
        let hidden = search == nil ? max(0, all.count - rowLimit) : 0
        let shown = hidden > 0 ? Array(all.suffix(rowLimit)) : all
        let epoch = rowStore.update(shown.map { rowKey($0, tools: tools, canType: canType, state: state) },
                                    chat: self, isNew: isNew)
        let shownReplies = outbox.shown(in: feed.items, search: search)
        return conversation(shown: shown, hidden: hidden, epoch: epoch, loose: loose, shownReplies: shownReplies, state: state)
    }

    /// The conversation's scroll view: an AppKit table on the Mac (see `ChatTable`), SwiftUI elsewhere.
    @ViewBuilder
    private func conversation(shown: [Row], hidden: Int, epoch: Int, loose: [ChatFeed.SubagentInfo],
                              shownReplies: [ReplyDelivery], state: String?) -> some View {
        let noMatches = search != nil && shown.isEmpty && shownReplies.isEmpty
        #if os(macOS)
        macTable(shown: shown, hidden: hidden, loose: loose, shownReplies: shownReplies, noMatches: noMatches, state: state)
        #else
        ScrollView {
            // Not lazy: every row is measured, so the list never grows by an estimate and shrinks
            // back (a jump on every arrival), and a conversation about one screen tall doesn't flip
            // between estimated and real heights (the list drifting by itself).
            ChatRows(alignment: .leading, spacing: 18) {
                #if os(iOS)
                if search == nil { placeholder }
                #endif
                if hidden > 0 {
                    Button {
                        let first = shown.first?.id
                        rowLimit += Self.rowPage
                        // Stay where you were: the earlier rows land above it.
                        if let first { position.scrollTo(id: first, anchor: .top) }
                    } label: {
                        Label("Earlier messages", systemImage: "arrow.up")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                    }
                    .macPlainButton()
                    .foregroundStyle(palette.secondary)
                    .accessibilityHint("\(hidden) more")
                }
                Group {
                    // The chat's body runs on every streamed token, every key typed and every
                    // change of the agent's status: the rows are gone through again only when one
                    // of them changed, and only the changed ones are built (see `RowList`).
                    RowList(store: rowStore, epoch: epoch)
                }

                // The read conversation arrives in one step: fade it in where it lands (no slide).
                .opacity(feed.items.isEmpty ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: feed.items.isEmpty)
                trailingRows(shownReplies: shownReplies, loose: loose, noMatches: noMatches, state: state)
            }
            .modifier(IdleHitTesting(state: scroll))
            // The whole list slides as one (on the stack, not the rows' Group: a Group hands its
            // modifiers to each row, and each row got its own clip, cutting off letters).
            .modifier(MessageTimeReveal.Slide(pull: timeReveal))
            // Not a scroll target layout: with one, the scroll position followed the top row as
            // the list scrolled, and each change rebuilt the chat and redrew its text (slow on the
            // Mac). Showing earlier rows still scrolls to the old first row by its id.
            // No layout animations on arrivals (rows, sent replies, the working line, sub-agents):
            // see ArriveIn. Searching still animates, since nothing is arriving then.
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
        // Drag sideways to see when each message was written (like Messages); it springs back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onChanged { value in
                    let dx = value.translation.width
                    guard dx < 0, abs(dx) > abs(value.translation.height) * 2 else { return }
                    timeReveal.offset = MessageTimeReveal.clamp(dx)
                }
                .onEnded { _ in
                    guard timeReveal.offset != 0 else { return }
                    withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) { timeReveal.offset = 0 }
                })
        .onScrollPhaseChange { _, phase in
            if scroll.scrolling != phase.isScrolling { scroll.scrolling = phase.isScrolling }
            if phase == .interacting, bounce.tripped { bounce.reset() }
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(bounce.tripped ? nil : .bottom, for: .sizeChanges)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { _, height in
            if bounce.record(height: height, at: Date.now.timeIntervalSinceReferenceDate,
                             userScrolling: scroll.scrolling) {
                let r = bounce.range.map { "\(Int($0.lowerBound))↔\(Int($0.upperBound)) pt" } ?? "?"
                AuthTrail.note("Scroll: chat kept bouncing (\(r), \(feed.items.count) items, "
                               + "state \(state ?? "-")); held still")
            }
        }
        .onChange(of: feed.items.count) { if bounce.tripped { bounce.reset() } }
        #if DEBUG
        .modifier(BounceProbe(feed: feed, terminal: terminal, model: model, state: state,
                              on: UserDefaults.standard.bool(forKey: "bergr.bounceProbe")))
        #endif
        // Only which side of each threshold the bottom is on, not the distance itself: a value that
        // changed every scroll frame ran this every frame (and was most of a scroll's main-thread
        // time on the Mac). Thresholds: following within 48 pt, the jump button above 600 pt and
        // hidden again within 150 pt.
        .onScrollGeometryChange(for: BottomDistance.self) { geometry in
            BottomDistance(below: geometry.contentSize.height - geometry.visibleRect.maxY)
        } action: { _, distance in
            bottomChanged(distance)
        }
        #endif
    }

    /// The jump-to-latest button shows well above the bottom, and hides only near it again: no
    /// flicker at the edge.
    private func bottomChanged(_ distance: BottomDistance) {
        let away = awayFromLatest ? distance.beyond150 : distance.beyond600
        if away != awayFromLatest {
            if away { seenMessages = messageCount }
            withAnimation(motion) { awayFromLatest = away }
        }
    }

    private func scrollToLatest(animated: Bool) {
        #if os(macOS)
        scrollControl.scrollToBottom(animated: animated)
        #else
        if animated { withAnimation(motion) { position.scrollTo(edge: .bottom) } } else { position.scrollTo(edge: .bottom) }
        #endif
    }

    #if os(macOS)
    /// The rows as the Mac's table shows them (see `ChatTable`): "Earlier messages", the
    /// conversation's rows (each rebuilt only when its `RowStore` version changes), and one row
    /// for what follows them.
    private func macTable(shown: [Row], hidden: Int, loose: [ChatFeed.SubagentInfo], shownReplies: [ReplyDelivery],
                          noMatches: Bool, state: String?) -> some View {
        var items: [ChatTableItem] = []
        items.reserveCapacity(rowStore.slots.count + 2)
        if hidden > 0 {
            let palette = palette
            items.append(ChatTableItem(id: "chat.earlier", version: hidden) {
                AnyView(Button {
                    // The table keeps the rows you look at still as earlier ones land above.
                    rowLimit += Self.rowPage
                } label: {
                    Label("Earlier messages", systemImage: "arrow.up")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                }
                .macPlainButton()
                .foregroundStyle(palette.secondary)
                .accessibilityHint("\(hidden) more"))
            })
        }
        for slot in rowStore.slots {
            items.append(ChatTableItem(id: slot.id, version: slot.version) {
                AnyView(RowSlot(box: slot.box, version: slot.version)
                    .contentShape(.rect)
                    .modifier(ArriveIn(active: slot.new)))
            })
        }
        let others = search == nil ? othersQueued(shownReplies) : []
        let working = search == nil && state == "working"
        let showsCodexActivity = search == nil && agent == .codex
        if !loose.isEmpty || !shownReplies.isEmpty || !others.isEmpty || working || showsCodexActivity || useClaudeTerminalHistory || noMatches {
            var hasher = Hasher()
            hasher.combine(colorScheme == .dark)
            hasher.combine(noMatches)
            hasher.combine(state)
            if !loose.isEmpty { hasher.combine(String(describing: loose)) }
            for reply in shownReplies {
                hasher.combine(reply.id)
                hasher.combine(String(describing: reply.phase))
                hasher.combine(reply.text)
                hasher.combine(reply.entered)
            }
            hasher.combine(others)
            hasher.combine(showsCodexActivity)
            hasher.combine(useClaudeTerminalHistory)
            if working {
                hasher.combine(liveRunID == nil ? terminal?.status?.msg ?? terminal?.status?.title : nil)
                hasher.combine(workingSince)
            }
            items.append(ChatTableItem(id: "chat.trailing", version: hasher.finalize()) {
                AnyView(VStack(alignment: .leading, spacing: 18) {
                    trailingRows(shownReplies: shownReplies, loose: loose, noMatches: noMatches, state: state)
                })
            })
        }
        // Under the bars, which the table keeps its rows clear of as content insets: the reply
        // bar's and the header's measured heights (the toolbar's the table reads from the window).
        return ChatTable(items: items, insets: EdgeInsets(top: macBars.top, leading: 0, bottom: macBars.bottom, trailing: 0),
                         control: scrollControl) { distance in
            bottomChanged(distance)
        }
        .ignoresSafeArea(.container, edges: .vertical)
    }
    #endif

    /// What follows the rows: sub-agents without a row, sent replies, the working line, "No matches".
    @ViewBuilder
    private func trailingRows(shownReplies: [ReplyDelivery], loose: [ChatFeed.SubagentInfo], noMatches: Bool,
                              state: String?) -> some View {
        if search == nil, useClaudeTerminalHistory {
            ClaudeTerminalHistory(model: model, palette: palette)
        }
        // A sent reply shows at once; when the conversation has it, the real one takes
        // its place without moving, and this one goes in the same instant.
        ForEach(shownReplies) { reply in
            VStack(alignment: .trailing, spacing: 6) {
                if agent == .codex {
                    ForEach(reply.images) { image in
                        ImageBubble(data: image.data, fromUser: true, palette: palette)
                    }
                }
                if agent != .codex || reply.images.isEmpty || !reply.payload.typed.isEmpty {
                    UserBubble(text: agent == .codex && reply.payload.hasImages ? reply.payload.typed : reply.text, palette: palette)
                        .opacity(0.55)
                        // Sent while the agent works, it waits in the agent's queue: long-press
                        // can stop the agent so it's read now.
                        .contextMenu {
                            if state == "working", reply.phase != .failed, !reply.payload.isShellCommand {
                                Button("Send Now", systemImage: "bolt.fill") { pushNow() }
                            }
                            copyButton(reply.text)
                        }
                        .accessibilityLabel(reply.phase == .failed ? "Not delivered: \(reply.text)" : "Sending: \(reply.text)")
                }
                if reply.phase == .unconfirmed {
                    Label(reply.payload.isShellCommand ? "Command result unconfirmed" : "Delivery unconfirmed",
                          systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .contextMenu {
                            Button("Dismiss") { outbox.discard(reply.id) }
                        }
                } else if agent == .codex, reply.payload.isShellCommand, reply.entered {
                    Label("Command submitted · waiting for result", systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                } else if reply.phase == .queued || reply.phase == .pushed {
                    Label(reply.phase == .pushed ? "Sending now" : "Queued, the agent reads it after this step",
                          systemImage: reply.phase == .pushed ? "bolt.fill" : "clock")
                        .font(.caption)
                        .foregroundStyle(reply.phase == .pushed ? palette.accent : palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity)
                }
                if reply.phase == .failed {
                    HStack(spacing: 12) {
                        Label("Not delivered", systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(palette.secondary)
                        Button("Retry") { prepared().retry(reply.id) }
                            .font(.footnote.weight(.semibold))
                            .frame(minHeight: PlatformMetrics.controlHeight)
                        Button("Discard", systemImage: "xmark") {
                            withAnimation(motion) { outbox.discard(reply.id) }
                        }
                        .labelStyle(.iconOnly)
                        .font(.footnote)
                        .foregroundStyle(palette.secondary)
                        .frame(minWidth: PlatformMetrics.controlHeight, minHeight: PlatformMetrics.controlHeight)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .modifier(ArriveIn(active: true))
            .transition(.identity)
        }
        // Queued in the agent from elsewhere (typed in its terminal, another device):
        // shown like ours, without Retry. Ours are already above.
        if search == nil {
            ForEach(Array(othersQueued(shownReplies).enumerated()), id: \.offset) { _, text in
                VStack(alignment: .trailing, spacing: 6) {
                    let parts = SentImages.split(text)
                    ForEach(parts.paths, id: \.self) { path in
                        SentImageView(path: path, session: session, palette: palette)
                    }
                    if !parts.text.isEmpty || parts.paths.isEmpty {
                        UserBubble(text: parts.text, palette: palette)
                            .opacity(0.55)
                            .contextMenu {
                                if state == "working" {
                                    Button("Send Now", systemImage: "bolt.fill") { pushNow() }
                                }
                                copyButton(parts.text)
                            }
                            .accessibilityLabel("Queued: \(parts.text)")
                    }
                    Label("Queued, the agent reads it after this step", systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .modifier(ArriveIn(active: true))
                .transition(.identity)
            }
        }
        if search == nil, agent == .codex {
            CodexLiveCommandRow(model: model, palette: palette)
        }
        if search == nil, state == "working", !waitingOnQuestion {
            // herdr's status is mostly the agent's description of its current tool, which
            // the live tool run above already shows; it only adds something between tools.
            WorkingRow(agent: agent,
                       detail: liveRunID == nil ? terminal?.status?.msg ?? terminal?.status?.title : nil,
                       palette: palette, since: workingSince)
                // Fades in by drawing alone, and makes way for the reply at once.
                .modifier(ArriveIn(active: true, rise: false))
                .transition(.identity)
        }
        // What's running now (sub-agents, background commands), under the working line where
        // the eye already is; still shown after the turn ends while they run.
        if !loose.isEmpty {
            SubagentGroup(agents: loose, palette: palette, open: loose.count <= 5)
                .transition(.opacity)
        }
        if noMatches {
            Text("No matches")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var chatToolbar: some ToolbarContent {
            // The context gauge, with the other buttons. It's a custom view, so it says it can go
            // vertical: on the Duo the bar's buttons move to the side strip, and without this it
            // stayed behind alone in the title bar.
        #if os(iOS)
        if #available(iOS 27.1, *) {
            contextItem.axisBehavior(.verticalPreferred)
        } else {
            contextItem
        }
        #endif
        // On the Mac the inspector shows context, limits and the permission mode, which leaves only
        // Search: its own button rather than a ⋯ menu of one.
        #if os(macOS)
            ToolbarItem(placement: .trailingAction) {
                Button("Search", systemImage: "magnifyingglass") {
                    withAnimation(motion) { searching = true }
                    searchFocused = true
                }
                .help("Search Conversation (⌘F)")
            }
            ToolbarItem(placement: .trailingAction) {
                Menu("Conversation", systemImage: "square.and.arrow.up") {
                    ConversationExportButtons(feed: feed, agent: agent)
                }
                .menuIndicator(.hidden)
            }
        #else
            ToolbarItem(placement: .trailingAction) { changesButton }
            ToolbarItem(placement: .trailingAction) { moreMenu }
        #endif
    }

    /// The chat's buttons, for the system bar's items and for a pane's own header.
    @ViewBuilder
    private var chatButtons: some View {
        changesButton
        contextButton
        moreMenu
    }

    /// Its own view: it reads the terminal's screen (for the permission mode), which changes many
    /// times a second while an agent works, and read here that rebuilt the whole chat each time.
    private var moreMenu: some View {
        MoreMenuSlot(
            agent: agent, feed: feed, model: model, hasInfo: onInfo != nil, canSetMode: canType,
            lifecycle: lifecycle, canManage: manageable,
            end: {
                guard let terminal, let session else { return }
                lifecycle.end(session: session, terminal: terminal, interrupt: { model.press(.escape) })
            },
            restart: {
                guard let terminal, let session else { return }
                lifecycle.restart(session: session, terminal: terminal, agent: agent, conversationID: feed.conversationID)
            },
            choosingMode: $choosingMode, sendError: $sendError,
            search: {
                withAnimation(motion) { searching = true }
                searchFocused = true
            },
            usage: { showingUsage = true },
            info: { onInfo?() })
    }

    private var changesButton: some View {
        Button("Changes", systemImage: "plusminus") { showingChanges = true }
            .disabled(terminal?.cwd.isEmpty != false)
    }

    /// A live agent terminal on this machine's own core, with a connection to act through.
    private var manageable: Bool {
        guard let terminal, session != nil else { return false }
        return terminal.isLive && !terminal.address.contains("/")
    }

    private var contextItem: some ToolbarContent {
        ToolbarItem(placement: .trailingAction) { contextButton }
    }

    private var contextButton: some View {
        Button { showingUsage = true } label: {
            UsageRing(fraction: feed.usage?.fraction ?? 0, palette: palette)
        }
        // In the Mac toolbar the system's toolbar style does the hit testing: with a plain style the
        // thin ring barely took clicks, and a full-frame shape stole the next button's.
        #if os(iOS)
        .macPlainButton()
        #endif
        .help("Context")
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
                    .frame(width: PlatformMetrics.controlHeight, height: PlatformMetrics.controlHeight)
                    .contentShape(Rectangle())
            }
            .macPlainButton()
            .accessibilityLabel("Close search")
        }
        .padding(.leading, 14)
        .foregroundStyle(palette.text)
        .glassEffect(.regular, in: Capsule())
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var liveModelStatus: (model: String, effort: String?)? {
        switch agent {
        case .codex: CodexModelStatus.read(model.textLines)
        case .antigravity: AntigravityStatus.read(model.textLines)
        case .claude: nil
        }
    }

    private var currentModel: ChatFeed.ModelOption? {
        guard let id = (liveModelStatus?.model ?? feed.usage?.model)?.lowercased() else { return nil }
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
            CompactChip(draft: $draft, palette: palette, fraction: feed.usage?.fraction, state: state, agent: agent)
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
            if let session { CoreUpdateBanner(session: session) }
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if ReplyDrafts.hasUnsent(for: draftKey), ReplyDrafts.text(for: draftKey) == draft {
                Label("Not sent — tap Send to try again", systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let reset = limitReset {
                LimitBar(reset: reset, scheduler: limitScheduler, draft: $draft, palette: palette)
                    .transition(arrival)
            }
            if let terminal, terminal.isLive {
                // Not while a question card is open: the cards answer it, and the screen-guessed
                // buttons (Yes, No, Return, Esc) only showed without the question.
                Isolated {
                    let scope = session.map {
                        ApprovalScope(machine: $0.host.id.uuidString, machineName: $0.host.name,
                                      cwd: terminal.foreground?.cwd ?? terminal.cwd,
                                      agent: terminal.status?.app ?? terminal.displayName)
                    }
                    // The demo's Codex question is answered from its card and the reply box: its
                    // made-up terminal has no menu for the screen-read buttons to press.
                    let demo = session?.host.isDemo == true
                    AnswerSlot(terminal: terminal, model: model,
                               blocked: state == "blocked" && !questionOpen && !(demo && openCodexQuestion != nil), palette: palette,
                               transition: arrival, scope: scope, demo: demo) { question, answer in
                        feed.recordDecision(question: question, answer: answer)
                        ApprovalLog.record(
                            machine: session?.host.name ?? "", agent: terminal.status?.app ?? terminal.displayName,
                            question: question, answer: answer, source: .card,
                            command: ApprovalRuleMatcher.promptCommand(
                                lines: model.frame.textLines, cols: model.frame.cols, agent: terminal.status?.app),
                            cwd: scope?.cwd, hostID: scope?.machine)
                    }
                }
            }
            if !replyChips.isEmpty {
                ReplyChips(chips: replyChips, draft: $draft, palette: palette, answer: openCodexQuestion.map { open in
                    { chip in answerCodexQuestion(chip, title: open.title, id: open.id) }
                })
                    .transition(.opacity)
            }
            inputBar
        }
        .animation(motion, value: state)
        .animation(motion, value: replyChips)
        .task(id: replyKey) {
            // Once per assistant message, when its turn has finished (see `ReplySuggestions`).
            guard let last = feed.items.last, case .assistant(let text, _) = last.kind else { return }
            let userRequest = feed.items.dropLast().reversed().lazy.compactMap { item -> String? in
                if case .user(let text) = item.kind { return text }
                return nil
            }.first ?? ""
            let context = feed.items.dropLast().reversed().lazy.compactMap { item -> String? in
                switch item.kind {
                case .user(let text): return "User: " + OnDeviceText.truncate(text, to: 700)
                case .assistant(let text, _): return "Agent: " + OnDeviceText.truncate(text, to: 700)
                default: return nil
                }
            }.prefix(6).reversed().joined(separator: "\n")
            await ReplySuggestions.shared.request(messageID: last.id, text: text,
                                                   working: state == "working", context: context, userRequest: userRequest)
        }
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
        .background { shortcuts }
    }

    /// The last message's id, and whether the agent is still working on it.
    private var replyKey: String {
        "\(feed.items.last?.id ?? "")|\(state == "working")"
    }

    /// Suggested replies after the agent's last message: only once its turn is done, and while
    /// nothing is typed or attached (they're hidden then).
    private var replyChips: [String] {
        guard state != "working", draft.isBlank, attachments.isEmpty,
              let last = feed.items.last, case .assistant = last.kind else { return [] }
        return ReplySuggestions.shared.chips[last.id] ?? []
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
    #if os(macOS)
    static let readableWidth: CGFloat = 820
    #else
    static let readableWidth: CGFloat = 720
    #endif

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
        Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(text) }
        ShareLink("Share…", item: TranscriptExport.plain(text))
        commandButtons(Commands.cachedIn(text))
        #if os(iOS)
        Button("Select Text", systemImage: "selection.pin.in.out") { selecting = SelectableMessage(text: text) }
        #endif
    }

    /// Copy and Run for each command: Run sends it as a `!` shell command, the way typing it would
    /// (only one-line commands, and only whole ones: a shortened one ends in "…").
    @ViewBuilder
    private func commandButtons(_ commands: [String]) -> some View {
        ForEach(commands, id: \.self) { command in
            let one = commands.count == 1
            Button(one ? "Copy Command" : "Copy “\(Commands.label(command))”", systemImage: "doc.on.clipboard") {
                Pasteboard.copy(command)
            }
            if Commands.runnable(command) {
                Button(one ? "Run Command" : "Run “\(Commands.label(command))”", systemImage: "terminal") {
                    run(command)
                }
                .disabled(!canType)
            }
        }
    }

    /// Picks an option of Claude's question in the terminal: its number picks it and moves to the
    /// next question; after the last, the review screen ("Ready to submit your answers?") has
    /// Submit selected, so Return sends them.
    private func pick(_ choice: String, in options: [String], question id: String, info: ChatFeed.QuestionInfo) {
        guard let at = options.firstIndex(of: choice), at < 9, canType else { return }
        if model.watching { model.setWatching(false) }
        questionPicks[id] = choice
        let last = info.index == info.count - 1
        Task { @MainActor in
            await model.automate {
                model.type(String(at + 1))
                guard last else { return }
                await waitForScreen(upTo: .seconds(3)) { lines in
                    lines.contains { $0.contains("Ready to submit your answers?") }
                }
                if model.frame.textLines.contains(where: { $0.contains("Ready to submit your answers?") }) {
                    model.press(.enter)
                }
            }
        }
    }

    /// Approves a call Claude's auto mode blocked and runs it again: /permissions opens on
    /// "Recently blocked"; the row whose command shows under it gets r (retry), and Esc closes the
    /// menu, which retries it. The card turns to "Allowed" when the same call shows up again.
    private func allowBlocked(_ id: String, summary: String) {
        guard canType, !blockedSending.contains(id) else { return }
        if model.watching { model.setWatching(false) }
        blockedSending.insert(id)
        let needle = BlockedCard.needle(summary)
        Task { @MainActor in
            var problem: String?
            await model.automate {
                model.type("/permissions")
                try? await Task.sleep(for: .milliseconds(150))
                model.press(.enter)
                await waitForScreen(upTo: .seconds(3)) { lines in lines.contains { $0.contains("to retry") } }
                guard model.frame.textLines.contains(where: { $0.contains("to retry") }) else {
                    model.press(.escape)
                    problem = "Claude didn't show its recently blocked list. Approve it in the terminal with /permissions."
                    return
                }
                for _ in 0..<12 {
                    if BlockedCard.shows(needle, in: model.frame.textLines) {
                        model.type("r")
                        try? await Task.sleep(for: .milliseconds(250))
                        model.press(.escape)
                        return
                    }
                    model.press(.down)
                    try? await Task.sleep(for: .milliseconds(200))
                }
                model.press(.escape)
                problem = "Couldn't find that command in Claude's recently blocked list. Approve it in the terminal with /permissions."
            }
            if let problem {
                sendError = problem
                blockedSending.remove(id)
            } else {
                // Not retried after a while (the menu didn't take it): the button works again.
                try? await Task.sleep(for: .seconds(20))
                blockedSending.remove(id)
            }
        }
    }

    /// Claude's question waiting in the terminal (AskUserQuestion), unanswered, while the agent is
    /// stopped on it.
    private var openClaudeQuestion: (id: String, info: ChatFeed.QuestionInfo)? {
        guard state == "blocked",
              let last = feed.items.last(where: { if case .question = $0.kind { return true }; return false }),
              let info = feed.questionInfo[last.id], info.keys, !info.codexAsync, info.answer == nil,
              questionPicks[last.id] == nil else { return nil }
        let after = feed.items.drop { $0.id != last.id }.dropFirst()
        guard !after.contains(where: { if case .user = $0.kind { return true }; return false }) else { return nil }
        return (last.id, info)
    }

    /// Answers Claude's open question with your own words: picks its "Type something." option
    /// (by the number the screen shows), types the text there and sends it. Never types into the
    /// menu itself.
    private func answerClaudeInOwnWords(_ text: String, question id: String, info: ChatFeed.QuestionInfo) {
        guard canType else { return }
        if model.watching { model.setWatching(false) }
        let last = info.index == info.count - 1
        Task { @MainActor in
            await model.automate {
                guard let own = AnswerParser.choices(in: model.frame.textLines)
                    .first(where: { $0.label.lowercased().hasPrefix("type something") }) else {
                    sendError = "Couldn't find Claude's “Type something” option. Answer in the terminal."
                    draft = text
                    return
                }
                questionPicks[id] = text
                model.type(String(own.number))
                try? await Task.sleep(for: .milliseconds(300))
                model.paste(text)
                try? await Task.sleep(for: .milliseconds(150))
                model.press(.enter)
                guard last else { return }
                await waitForScreen(upTo: .seconds(3)) { lines in
                    lines.contains { $0.contains("Ready to submit your answers?") }
                }
                if model.frame.textLines.contains(where: { $0.contains("Ready to submit your answers?") }) {
                    model.press(.enter)
                }
            }
        }
    }

    /// Codex's newest unanswered async question, which a reply should answer (a plain message
    /// would be queued as a new instruction instead).
    private var openCodexQuestion: (id: String, title: String)? {
        CodexQuestionReply.open(items: feed.items.map { item in
            if case .question(let title, _) = item.kind { return (item.id, title) }
            return nil
        }, info: { id in feed.questionInfo[id].map { ($0.codexAsync, $0.answer != nil) } },
           picked: { questionPicks[$0] != nil || questionSending.contains($0) },
           lastUserMessage: feed.items.lastIndex { if case .user = $0.kind { return true }; return false })
    }

    /// When the agent can go on, if it's out of usage: from the plan numbers when a window is full,
    /// else from its own "You've hit your limit · resets 11pm" message among the latest ones (the
    /// numbers can lag behind, or be missing).
    private var limitReset: Date? {
        if let usage = feed.usage, let reset = ScheduledSend.limitingReset(session: usage.session, weekly: usage.weekly) {
            return reset
        }
        // Only the agent's latest message counts, and only while it isn't working: once it answers
        // again (the limit reset), the old message no longer applies. The reset is the next such
        // time after the message was written; one already past means the limit is over.
        guard state != "working",
              let last = feed.items.last(where: {
                  if case .assistant = $0.kind { return true }
                  if case .user = $0.kind { return true }
                  return false
              }),
              case .assistant(let text, _) = last.kind,
              let reset = ScheduledSend.resetFromMessage(text, now: feed.sentAt[last.id] ?? .now),
              reset > .now
        else { return nil }
        return reset
    }

    /// Has the agent's machine send a message later (the limit bar's "Continue Then").
    private var limitScheduler: ScheduleRunner? {
        guard let session, let terminal else { return nil }
        return ScheduleRunner(
            address: terminal.address, windows: session.isWindowsHost, machine: session.host.name,
            helperReady: session.host.isDemo
                || (PushRegistration.shared.helperVersion[session.host.id] ?? 0) >= ScheduledSend.minHelperVersion,
            run: { command in try await session.commandOutput(command.command, input: command.input) })
    }

    private func answerCodexQuestion(_ answer: String, title: String, id: String) {
        guard canType, questionPicks[id] == nil, !questionSending.contains(id) else { return }
        questionSending.insert(id)
        if model.watching { model.setWatching(false) }
        let pending = feed.questionInfo.values.filter { $0.codexAsync && $0.answer == nil }.count
        Task { @MainActor in
            defer { questionSending.remove(id) }
            await model.automate {
                let result = await CodexQuestionReply.sendResult(answer, title: title, pendingCount: pending,
                    lines: { model.frame.textLines },
                    previous: { model.press(.left, modifiers: .shift) },
                    paste: { model.paste($0) }, submit: { model.press(.enter) },
                    choose: { model.type(String($0)) },
                    confirmed: { feed.questionInfo[id]?.answer != nil })
                switch result {
                case .sent:
                    questionPicks[id] = answer
                case .unconfirmed:
                    questionPicks[id] = answer
                    sendError = "Choice sent, but confirmation hasn’t arrived. Check the terminal."
                case .notSent:
                    sendError = "Couldn't select this Codex question. Your answer wasn't sent. Try again, or answer in the terminal."
                }
            }
        }
    }

    /// Runs a command in the agent's terminal as a `!` shell command, through the reply path (so it
    /// shows in the chat with its output); what's being written in the reply box stays there.
    private func run(_ command: String) {
        let keptDraft = draft, keptAttachments = attachments
        draft = "!" + command
        attachments = []
        send()
        draft = keptDraft
        attachments = keptAttachments
    }

    // MARK: Rows

    /// Items as shown: a run of tool calls between two messages reads as one line.
    private enum Row: Identifiable, Equatable {
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
    private func shownRows(_ rows: [Row]) -> [Row] {
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
                case .blocked(let reason, let summary, let description, _):
                    return [reason, summary, description].joined(separator: " ").localizedStandardContains(search) ? row : nil
                case .tool, .image, .imageLoading, .imageOnDemand:
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

    /// The id of the tool run the agent is in right now (a `Row.id`), if any.
    /// A row that joined the conversation just now (its first item arrived in the last moment).
    private func isNew(_ row: Row) -> Bool {
        let id: String
        switch row {
        case .item(let item): id = item.id
        case .tools(let items): id = items.first?.id ?? ""
        }
        guard let at = feed.arrivedAt[id] else { return false }
        return Date.now.timeIntervalSince(at) < 1.5
    }

    /// One of Claude's question cards is waiting for an answer.
    /// The agent stopped on a question card that isn't answered yet (Codex's async questions don't
    /// stop it): no "working" line under the card then, even if the status still says working.
    private var waitingOnQuestion: Bool {
        guard let last = feed.items.last(where: { if case .question = $0.kind { return true }; return false }),
              let info = feed.questionInfo[last.id] else { return false }
        let after = feed.items.drop { $0.id != last.id }.dropFirst()
        let moved = after.contains { if case .user = $0.kind { return true }; if case .assistant = $0.kind { return true }; return false }
        return !info.codexAsync && info.answer == nil && questionPicks[last.id] == nil && !moved
    }

    private var questionOpen: Bool {
        feed.items.suffix(12).contains { item in
            guard case .question = item.kind, let info = feed.questionInfo[item.id], info.keys else { return false }
            return info.answer == nil && questionPicks[item.id] == nil
        }
    }

    /// Messages (yours, the agent's, images, answers), not tool steps: what "N new" counts.
    private var messageCount: Int {
        feed.items.count { item in
            switch item.kind {
            case .tool: false
            default: true
            }
        }
    }

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

    /// Sub-agents and background commands still running: listed at the bottom of the chat. A
    /// finished one sits with the tool call that started it (one whose call isn't loaded has
    /// nowhere to sit, and piling those at the end of every visit only buries the conversation).
    private var looseSubagents: [ChatFeed.SubagentInfo] {
        feed.subagents.filter { $0.state == .running }
    }

    /// What every tool row needs, worked out once per body rather than per row.
    private struct ToolContext {
        let liveRunID: String?
        let agents: [ChatFeed.SubagentInfo]
        let lastRowID: String?
        let started: Set<String>
        init(liveRunID: String?, agents: [ChatFeed.SubagentInfo], lastRowID: String?) {
            self.liveRunID = liveRunID
            self.agents = agents
            self.lastRowID = lastRowID
            started = Set(agents.compactMap(\.parent))
        }
    }

    /// Everything a row shows or acts on that can change, so an unchanged row is skipped (see
    /// `RowSlot`). What a row needs from the feed or the terminal goes through here: read inside
    /// the row, a change to any tool's output or any question would redraw every row that read it.
    private struct RowKey: Equatable {
        let row: Row
        let scheme: ColorScheme
        let reduceMotion: Bool
        let canType: Bool
        let session: ObjectIdentifier?
        let address: String?
        // A tool run: its steps with their output, the sub-agents it started, and its state.
        var steps: [ToolRun.Step] = []
        var agents: [ChatFeed.SubagentInfo] = []
        var running = false
        var waiting = false
        /// When an assistant message arrived, while it reveals.
        var reveal: Date?
        // A question card.
        var info: ChatFeed.QuestionInfo?
        var earlierOpen = false
        var answer: String?
    }

    private func rowKey(_ row: Row, tools: ToolContext, canType: Bool, state: String?) -> RowKey {
        var key = RowKey(row: row, scheme: colorScheme, reduceMotion: reduceMotion, canType: canType,
                         session: session.map(ObjectIdentifier.init), address: terminal?.address)
        switch row {
        case .tools(let items):
            // The tool call that started a sub-agent is replaced by the sub-agent's row.
            let started = tools.started
            key.steps = items.compactMap { item -> ToolRun.Step? in
                if case .tool(let name, let summary) = item.kind, !started.contains(item.id) {
                    ToolRun.Step(id: item.id, name: name, summary: summary,
                                 output: feed.toolOutput[item.id].flatMap { $0.isEmpty ? nil : $0 },
                                 failed: feed.toolFailed.contains(item.id))
                } else { nil }
            }
            if !tools.agents.isEmpty {
                key.agents = tools.agents.filter { a in a.parent.map { p in items.contains { $0.id == p } } ?? false }
            }
            let id = row.id
            key.running = id == tools.liveRunID && (key.steps.last.map { feed.toolOutput[$0.id] == nil && !$0.failed } ?? false)
            key.waiting = state == "blocked" && id == tools.lastRowID
        case .item(let item):
            switch item.kind {
            case .assistant:
                key.reveal = feed.revealStart[item.id]
            case .blocked:
                key.waiting = blockedSending.contains(item.id)
            case .question:
                key.waiting = questionSending.contains(item.id)
                if let info = feed.questionInfo[item.id], info.keys || info.codexAsync {
                    // Claude's: picked in the terminal by number, one question after another.
                    key.info = info
                    key.earlierOpen = info.keys && info.index > 0 && info.group.map { group in
                        (0..<info.index).contains { i in
                            let id = "\(group)-q\(i)"
                            return feed.questionInfo[id]?.answer == nil && questionPicks[id] == nil
                        }
                    } == true
                    key.answer = info.answer ?? questionPicks[item.id]
                } else {
                    key.answer = answer(after: item.id)
                }
            default:
                break
            }
        }
        return key
    }

    @ViewBuilder
    private func rowView(_ key: RowKey) -> some View {
        let palette = ChatPalette.of(key.scheme)
        switch key.row {
        case .tools:
            let steps = key.steps
            VStack(alignment: .leading, spacing: 0) {
                if !steps.isEmpty {
                    ToolRun(steps: steps, palette: palette, running: key.running, waiting: key.waiting)
                        // The commands the agent ran: copy one, or run it again.
                        .contextMenu {
                            let commands = Commands.cachedRan(steps.map { ($0.name, $0.summary) })
                            if !commands.isEmpty { commandButtons(commands) }
                        }
                }
                if !key.agents.isEmpty { SubagentGroup(agents: key.agents, palette: palette) }
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
                VStack(alignment: .leading, spacing: 10) {
                    Group {
                        if !key.reduceMotion, let since = key.reveal {
                            RevealingMarkdown(blocks: blocks, palette: palette, since: since)
                        } else {
                            MarkdownView(blocks: blocks, palette: palette)
                        }
                    }
                    let images = FileLoader.imagePaths(in: text)
                    if !images.isEmpty, let session, !session.host.isDemo {
                        let loader = FileLoader(windows: session.isWindowsHost) { try await session.commandOutput($0) }
                        NamedImages(paths: images, palette: palette,
                                    exists: { await loader.existing($0) },
                                    load: { await loader.loadImage($0) })
                    }
                }
                // Full width, leading: on the Mac's chat table a narrower stack was centered.
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    copyButton(text)
                    Button("Read Aloud", systemImage: "speaker.wave.2") { SpeechReader.shared.toggle(text) }
                }
            case .plan(let steps):
                PlanCard(steps: steps, palette: palette)
            case .image(let data, let fromUser):
                ImageBubble(data: data, fromUser: fromUser, palette: palette)
                    .transition(.opacity)
            case .imageLoading(let width, let height, let fromUser):
                ImagePlaceholder(width: width, height: height, fromUser: fromUser, palette: palette)
            case .imageOnDemand(let size, let width, let height, let fromUser, let fetching):
                ImagePlaceholder(width: width, height: height, fromUser: fromUser, palette: palette,
                                 sizeText: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                                 fetching: fetching) { feed.requestImage(id: item.id) }
            case .decision(let question, let answer):
                DecisionRow(question: question, answer: answer, palette: palette)
                    .transition(arrival)
            case .note(let text):
                NoteRow(text: text, palette: palette)
            case .question(let title, let options):
                if let info = key.info {
                    QuestionCard(title: title, options: options, details: info.details, header: info.header,
                                 numbered: !info.codexAsync, answer: key.answer, palette: palette,
                                 enabled: key.canType && !key.earlierOpen && !key.waiting,
                                 allowsText: true) { choice in
                        if info.codexAsync {
                            answerCodexQuestion(choice, title: title, id: item.id)
                        } else if options.contains(choice) {
                            pick(choice, in: options, question: item.id, info: info)
                        } else {
                            answerClaudeInOwnWords(choice, question: item.id, info: info)
                        }
                    }
                } else {
                    QuestionCard(title: title, options: options, answer: key.answer, palette: palette,
                                 enabled: key.canType) { choice in
                        draft = choice
                        send()
                    }
                }
            case .blocked(let reason, let summary, let description, let retried):
                BlockedCard(reason: reason, summary: summary, description: description, retried: retried,
                            sending: key.waiting, enabled: key.canType, palette: palette) {
                    allowBlocked(item.id, summary: summary)
                }
            case .tool:
                EmptyView()
            }
        }
    }

    /// One row of the conversation, built again only when what it shows changed. The rows' builder
    /// is a function of the whole chat, so without this every streamed token built all of them.
    ///
    /// Two plain words on purpose (a reference and a number), the same bit for bit while the row
    /// is unchanged. SwiftUI skips a view whose value is bitwise equal at once; anything it has to
    /// compare field by field or with `==` (also `.equatable()`) it only skips once it has worked
    /// out how to compare that type, in the background, seconds after the type first shows (longer
    /// on a busy machine). Until then such rows were all built on every token.
    private struct RowSlot: View {
        let box: RowBox
        let version: Int

        var body: some View {
            if let chat = box.store.chat { chat.rowView(box.key) }
        }
    }

    @MainActor
    private final class RowBox {
        var key: RowKey
        /// Counts the key's changes.
        var version = 0
        unowned let store: RowStore

        init(key: RowKey, store: RowStore) {
            self.key = key
            self.store = store
        }
    }

    private struct Slot: Identifiable, Equatable {
        let id: String
        let box: RowBox
        let version: Int
        /// Joined the conversation just now: it fades in.
        let new: Bool

        static func == (a: Slot, b: Slot) -> Bool {
            a.box === b.box && a.version == b.version && a.new == b.new
        }
    }

    /// The conversation's rows. Like `RowSlot`, the same bit for bit until a row changes, joins or
    /// leaves (`epoch` counts that), so the chat's body running for anything else skips the list.
    private struct RowList: View {
        let store: RowStore
        let epoch: Int
        /// How far a sideways drag has pulled the rows (see `MessageTimeReveal`).

        var body: some View {
            ForEach(store.slots) { slot in
                RowSlot(box: slot.box, version: slot.version)
                    .modifier(MessageTimeReveal(time: store.chat?.feed.sentAt[slot.id]))
                    // A row is hit as its box, not its text's outline: matching the outline
                    // on every pointer move made scrolling slow on the Mac.
                    .contentShape(.rect)
                    // Rows take their place at once (the list keeps its bottom still, and
                    // animating positions fought that: rows overshot up and settled back
                    // down); a new one fades and rises into place by drawing alone.
                    .modifier(ArriveIn(active: slot.new))
                    .transition(.identity)
            }
        }
    }

    /// The rows drawn and their keys. Not observable: it is brought up to date while the chat's
    /// body runs, and a row learns of its change through its `RowSlot`'s version.
    @MainActor
    private final class RowStore {
        /// The chat as last drawn, which builds the rows.
        var chat: ChatView?
        private var boxes: [String: RowBox] = [:]
        private(set) var slots: [Slot] = []
        /// Counts the changes to `slots`.
        private var epoch = 0

        /// Brings the rows up to date with their keys; the count of changes so far.
        func update(_ keys: [RowKey], chat: ChatView, isNew: (Row) -> Bool) -> Int {
            self.chat = chat
            var kept: [String: RowBox] = [:]
            kept.reserveCapacity(keys.count)
            let next = keys.map { key in
                let id = key.row.id
                let box: RowBox
                if let old = boxes[id] {
                    box = old
                    if old.key != key {
                        old.key = key
                        old.version &+= 1
                    }
                } else {
                    box = RowBox(key: key, store: self)
                }
                kept[id] = box
                return Slot(id: id, box: box, version: box.version, new: isNew(key.row))
            }
            boxes = kept
            if next != slots {
                slots = next
                epoch &+= 1
            }
            return epoch
        }
    }

    private var useClaudeTerminalHistory: Bool {
        agent == .claude && feed.items.isEmpty && !model.inLogin
            && model.claudeTranscriptWarning != nil
            && !AnswerParser.needsLogin(in: model.textLines)
    }

    @ViewBuilder
    private var placeholder: some View {
        if !useClaudeTerminalHistory { transcriptPlaceholder }
    }

    private var retryFeed: (() -> Void)? {
        guard let session else { return nil }
        return { [feed] in session.restartFeed(feed) }
    }

    @ViewBuilder
    private var transcriptPlaceholder: some View {
        if reading {
            // One spinner for both loading and live-but-not-caught-up, so its 30 s cap doesn't
            // start over when the conversation is found.
            ReadingSpinner(color: palette.secondary, onStuck: feed.reportStall, retry: retryFeed)
        } else {
        switch feed.phase {
        case .loading:
            EmptyView()
        case .noConversation:
            ContentUnavailableView(
                "No conversation yet", systemImage: "bubble.left.and.text.bubble.right",
                description: Text("Send \(agent.displayName) a message to start one."))
        case .failed(let message):
            ContentUnavailableView("Can't read the conversation", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        case .live:
            EmptyView()
        }
        }
    }

    /// Loading, or a conversation found and still being read (shown until it's all in).
    private var reading: Bool {
        switch feed.phase {
        case .loading: return true
        case .live: return feed.items.isEmpty && !feed.caughtUp
        default: return false
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
            if let open = openCodexQuestion, !shellMode {
                HStack(spacing: 8) {
                    Label(sendAsNewMessage ? "Sends as a new message" : "Answers: \(open.title)",
                          systemImage: sendAsNewMessage ? "text.bubble" : "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button(sendAsNewMessage ? "Answer instead" : "New message instead") { sendAsNewMessage.toggle() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(palette.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .accessibilityIdentifier("codex-question-target")
            }
            AttachmentStrip(attachments: $attachments, palette: palette)
                .padding(.horizontal, 12)
                .padding(.top, attachments.isEmpty ? 0 : 10)
            ComposerField(
                text: $draft, placeholder: prompt,
                textColor: PlatformColor(palette.text), placeholderColor: PlatformColor(palette.secondary),
                enabled: canType, onSubmit: { send() }
            ) { images in
                for image in images where attachments.count < ChatAttachment.limit {
                    if let item = ChatAttachment.make(from: image) { attachments.append(item) }
                }
            }
                .padding(.top, 12)
                .padding(.bottom, 4)
                .padding(.horizontal, 16)
            HStack(spacing: PlatformMetrics.composerSpacing) {
                if session != nil {
                    AttachButton(attachments: $attachments, palette: palette, enabled: canType)
                        .padding(.leading, 2)
                }
                ModelChip(usage: feed.usage, effort: feed.chosenEffort, agent: agent, palette: palette, enabled: canType,
                          open: feed.models.isEmpty ? nil : { showingModels = true },
                          screen: agent == .claude ? nil : model)
                // Long-press: the context and plan limits (also in ⋯ → Usage).
                .contextMenu {
                    if feed.usage != nil || agent == .claude {
                        Button("Usage", systemImage: "gauge.with.dots.needle.50percent") { showingUsage = true }
                    }
                }
                .padding(.leading, session == nil ? 6 : 0)
                Spacer(minLength: 0)
                DictationButton(draft: $draft, palette: palette, enabled: canType)
                // One button in one place: stop while the agent works and nothing is typed, send otherwise.
                let stops = state == "working" && draft.isBlank && attachments.isEmpty
                Button {
                    if stops { model.press(.escape) } else { send() }
                } label: {
                    Image(systemName: stops ? "stop.fill" : "arrow.up")
                        .font(stops ? .footnote : .body.weight(.semibold))
                        .foregroundStyle(stops ? palette.text : ready ? palette.onAccent : palette.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: PlatformMetrics.sendButtonSize, height: PlatformMetrics.sendButtonSize)
                        .background(ready && !stops ? palette.accent : palette.bubble, in: Circle())
                        .frame(width: PlatformMetrics.controlHeight, height: PlatformMetrics.controlHeight)
                        .contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .disabled(!ready && !stops)
                .accessibilityLabel(stops ? "Interrupt \(agent.displayName)" : "Send")
                .accessibilityIdentifier("send-button")
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
        // Started as the terminal's own program (New Session), Claude has no shell under it to type
        // the command into: quitting it ends the terminal. Start a new one resuming the conversation.
        let direct = terminal.map { !RestartCommand.isShell($0.argv) } ?? false
        let old = terminal
        withAnimation(motion) { feed.restartedIntoNewest() }
        // Unstructured: it outlives this chat, which goes away while Claude isn't running.
        Task { @MainActor in
            await model.automate {
                model.type("/exit")
                try? await Task.sleep(for: .milliseconds(150))
                model.press(.enter)
                let deadline = Date.now.addingTimeInterval(15)
                var exited = false
                while Date.now < deadline {
                    try? await Task.sleep(for: .milliseconds(300))
                    let now = session.terminal(address)
                    if now?.isLive != true { exited = true; break }
                    if let fg = now?.foreground, ChatAgent.detect(name: fg.name, argv: fg.argv) != .claude { exited = true; break }
                }
                try? await Task.sleep(for: .milliseconds(400))
                // Still running: starting another would put two Claudes on one conversation.
                guard exited else { return }
                if direct, let old {
                    let windows = session.isWindowsHost || old.argv.first?.lowercased().hasSuffix(".exe") == true
                    var request = RunRequest(argv: windows ? RestartCommand.arguments(argv: argv, conversation: id)
                                                           : ["sh", "-c", RestartCommand.directLine(command)], cwd: old.cwd)
                    var labels = [Terminal.seenLabel: "0"]
                    if let space = old.labels[HerdrAppLayout.spaceLabel] { labels[HerdrAppLayout.spaceLabel] = space }
                    request.labels = labels
                    // `popos/t7`: a linked machine's terminal starts on that machine.
                    if let slash = address.lastIndex(of: "/") { request.on = String(address[..<slash]) }
                    if let started = try? await session.run(request) {
                        NotificationCenter.default.post(name: RestartCommand.openTerminal, object: nil,
                            userInfo: ["host": session.host.id, "address": started.address])
                    }
                    return
                }
                model.type(RestartCommand.typedLine(command, windows: session.isWindowsHost))
                try? await Task.sleep(for: .milliseconds(150))
                model.press(.enter)
            }
            // Once the new Claude Code is writing, read its version fresh.
            try? await Task.sleep(for: .seconds(8))
            feed.reconnect()
        }
    }

    /// Types a line into the terminal and presses Return, the way a reply goes.
    private func typeLine(_ text: String) {
        guard canType else { return }
        if model.watching { model.setWatching(false) }
        Task {
            if model.menuOpen, state == "idle", !model.inLogin {
                guard await model.closeMenu() else {
                    sendError = "Couldn't close the open menu. Press Esc in the terminal, then try again."
                    return
                }
            }
            await model.automate {
                model.type(text)
                try? await Task.sleep(for: .milliseconds(150))
                model.press(.enter)
            }
        }
    }

    /// Stops the agent so the replies waiting in its queue are read now.
    private func pushNow() {
        withAnimation(motion) { prepared().pushNow() }
        pushes += 1
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

    /// The outbox, with what it needs from this view right now.
    private func prepared() -> ReplyOutbox {
        let session = session, feed = feed, address = terminal?.address, fallback = terminal, keys = keys
        let model = model
        #if DEBUG
        let previewWorking = previewWorking
        #else
        let previewWorking = false
        #endif
        outbox.motion = motion
        outbox.environment = ReplyEnvironment(
            terminal: model,
            agentState: {
                if feed.demoWorking || previewWorking { return "working" }
                // Read from the session each time: this view's own copy of the status doesn't change.
                if let session, let address, let live = session.terminal(address) { return live.status?.state }
                return fallback?.status?.state
            },
            feedItems: { feed.items },
            upload: { data in
                guard let session else { throw CocoaError(.fileNoSuchFile) }
                let path = try await session.uploadImage(data)
                SentImages.store(data, for: path)
                return path
            },
            reconnect: {
                guard let session else { return }
                model.stop()
                session.retry(keys: keys)
                let end = ContinuousClock.now + .seconds(20)
                while ContinuousClock.now < end, session.state != .connected {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                model.reconnect()
                let live = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < live, model.phase != .live {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            },
            conversationID: { feed.conversationID },
            agent: agent)
        return outbox
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
        if CodexQuestionReply.answersQuestion(text: text, hasImages: !images.isEmpty, sendAsNew: sendAsNewMessage),
           let open = openCodexQuestion {
            draft = ""
            sendError = nil
            answerCodexQuestion(text, title: open.title, id: open.id)
            return
        }
        // A Claude question is open in the terminal: typed text would land in its menu (where
        // letters like j/k move the highlight and Return picks an option). Answer it in your own
        // words instead, through its "Type something." option.
        if CodexQuestionReply.answersQuestion(text: text, hasImages: !images.isEmpty, sendAsNew: false),
           let open = openClaudeQuestion {
            draft = ""
            sendError = nil
            answerClaudeInOwnWords(text, question: open.id, info: open.info)
            return
        }
        // A slash-command menu is open (the agent reads as idle): typed text would land in it.
        // Close it first; if it won't close, keep the draft and say so.
        if model.menuOpen, state == "idle", !model.inLogin {
            guard !closingMenu else { return }
            closingMenu = true
            Task { @MainActor in
                let closed = await model.closeMenu()
                closingMenu = false
                if closed { send(interrupting: interrupting) }
                else { sendError = "Couldn't close the open menu. Press Esc in the terminal, then send again." }
            }
            return
        }
        sendAsNewMessage = false
        // Replying takes the terminal over, like typing in it does.
        if model.watching { model.setWatching(false) }
        draft = ""
        attachments = []
        sendError = nil
        sent += 1
        if session?.host.isDemo == true { feed.demoUserSaid(text) }
        if state == "working", interrupting { pushes += 1 }
        prepared().send(text: text, images: images, interrupting: interrupting) { error in
            // Nothing is sent; the reply comes back so it can be sent again.
            sendError = "Couldn't send the image: \(error.localizedDescription)"
            // Back in the box only if nothing new was typed there meanwhile.
            if draft.isEmpty && attachments.isEmpty {
                draft = text
                attachments = images
            }
        }
        // What you just sent is where you want to be: straight there, then the list's own
        // bottom anchoring follows it as it grows (an animated scroll would chase a moving end).
        scrollToLatest(animated: false)
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
    /// Off screen or with the app inactive the timeline stops; back after the reveal, it shows all.
    @State private var visible = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let total = MarkdownBlock.totalWords(blocks)
        let duration = RevealSchedule.duration(totalWords: total)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: done || !visible || scenePhase != .active)) { context in
            let words = RevealSchedule.revealedWords(elapsed: context.date.timeIntervalSince(since),
                                                     totalWords: total, reduceMotion: false)
            MarkdownView(blocks: blocks, palette: palette, revealed: done || words >= total ? nil : words)
        }
        .onAppear { visible = true; finishIfOver(duration) }
        .onDisappear { visible = false }
        .onChange(of: scenePhase) { _, phase in if phase == .active { finishIfOver(duration) } }
        .task {
            let left = duration - Date.now.timeIntervalSince(since)
            if left > 0 { try? await Task.sleep(for: .seconds(left + 0.1)) }
            done = true
        }
    }

    private func finishIfOver(_ duration: Double) {
        if !done, Date.now.timeIntervalSince(since) >= duration { done = true }
    }
}

private struct UserBubble: View {
    let text: String
    let palette: ChatPalette

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.hit("UserBubble")
        #endif
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
    @State private var open: Bool

    /// `open`: each one listed from the start (the running ones at the bottom of the chat).
    init(agents: [ChatFeed.SubagentInfo], palette: ChatPalette, open: Bool = false) {
        self.agents = agents
        self.palette = palette
        _open = State(initialValue: open)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func title(_ agents: [ChatFeed.SubagentInfo]) -> String {
        let running = agents.filter { $0.state == .running }.count
        let shells = agents.filter(\.isShell).count, others = agents.count - shells
        var parts: [String] = []
        if others > 0 { parts.append("\(others) sub-agent\(others == 1 ? "" : "s")") }
        if shells > 0 { parts.append("\(shells) background command\(shells == 1 ? "" : "s")") }
        var text = parts.joined(separator: ", ")
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
                        Image(systemName: agents.allSatisfy(\.isShell) ? "terminal" : "person.2.badge.gearshape")
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
                    .frame(minHeight: 30)
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
        // Compact rows, no negative padding: pulled up, they sat on top of a step's output box.
    }
}

private struct SubagentLine: View {
    let agent: ChatFeed.SubagentInfo
    let palette: ChatPalette
    /// A background shell's latest output, opened with a tap.
    @State private var showOutput = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func detail(now: Date) -> String {
        var parts: [String] = []
        if agent.isShell, agent.state != .unknown, let started = agent.started {
            let seconds = max(0, (agent.ended ?? now).timeIntervalSince(started))
            parts.append(agent.state == .running ? "running \(Self.duration(seconds))" : Self.duration(seconds))
        }
        if !agent.summary.isEmpty { parts.append(agent.summary) }
        if agent.steps > 0 { parts.append("\(agent.steps) \(agent.steps == 1 ? "step" : "steps")") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    /// "42s", "4m", "1h 5m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                guard agent.isShell, !agent.output.isEmpty else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)) { showOutput.toggle() }
            } label: {
                TimelineView(.periodic(from: .now, by: agent.isShell && agent.state == .running ? 1 : 3600)) { context in
                    line(detail: detail(now: context.date))
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(agent.isShell && !agent.output.isEmpty ? (showOutput ? "Hides its output" : "Shows its latest output") : "")
            if showOutput, !agent.output.isEmpty {
                Text(agent.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.text)
                    .lineLimit(12)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.leading, 26)
                    .transition(.opacity)
            }
        }
    }

    private func line(detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: agent.isShell ? "terminal" : "person.2.badge.gearshape")
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
                case .unknown: Image(systemName: "questionmark.circle").font(.footnote)
                case .failed: Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.red)
                }
            }
            .frame(width: 16)
        }
        .frame(minHeight: 30)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.isShell ? "Background command" : "Sub-agent") \(agent.name), \(agent.state.rawValue)\(detail)")
    }
}

/// A run of tool calls: one line that says what happened ("Ran 2 commands"), opening to every
/// step. The run the agent is still in says "Running…" with a shimmer.
struct ToolRun: View {
    struct Step: Identifiable, Equatable {
        let id: String
        let name: String
        let summary: String
        var output: String?
        /// The tool reported an error or a non-zero exit.
        var failed = false
    }

    let steps: [Step]
    let palette: ChatPalette
    var running = false
    /// The agent stopped on this run to ask: it hasn't happened yet, so it doesn't say "Ran".
    var waiting = false
    var summaries: ToolOutputSummaries = .shared
    @State private var open = false
    @Environment(\.scenePhase) private var summaryScenePhase
    /// The tallest the live run's output box has been (lines): it doesn't shrink mid-run.
    @State private var outputLines = 0
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

    /// One line, whatever it says: the on-device model's few words on what the steps did, once
    /// written ("Fix padding and rerun tests"), else the counts. Always one line, so the swap
    /// never changes the row's height (taller rows made the chat creep up).
    private var title: String {
        guard steps.count > 1, let gist = summaries.summary(for: stepsKey) else { return Self.title(steps) }
        return gist
    }

    private var stepsKey: String { "steps|" + (steps.last?.id ?? "") }

    /// Retry a missing summary when the app returns or the on-device model becomes available.
    private func summaryRequestKey(_ key: String) -> String {
        "\(key)|\(summaryScenePhase == .active)|\(OnDeviceText.isAvailable)"
    }

    /// The step whose output the second line sums up, once the run is done: the last failed one
    /// (its output says what went wrong), else the newest with output; only when that output is long.
    private var digestStep: Step? {
        guard !running, !waiting,
              let step = steps.last(where: { $0.failed && $0.output != nil }) ?? steps.last(where: { $0.output != nil }),
              let output = step.output, ToolOutputSummaries.isLong(output) else { return nil }
        return step
    }
    /// The one-line summary of that output, once written on the device.
    private var digest: String? { digestStep.flatMap { summaries.summary(for: $0.id) } }


    static func title(_ steps: [Step]) -> String {
        if steps.count == 1, let step = steps.first {
            let line = step.summary.split(separator: "\n").first.map(String.init) ?? ""
            let what = line.isEmpty ? step.name : line
            // Claude gives a command a description on its first line: that already reads as a
            // sentence ("Read the misplaced padding context"), without "Ran" in front.
            let described = step.summary.contains("\n") && !line.isEmpty
            switch kind(step.name) {
            case .command: return described ? line : "Ran " + what
            case .edit: return "Edited " + what
            case .read: return "Read " + what
            case .search: return "Searched " + what
            case .other: return line.isEmpty ? step.name : "\(step.name) · \(line)"
            }
        }
        // Claude described its commands: the latest description and how many more beats
        // "Ran 4 commands" (shown until, or instead of, the model's few words).
        if steps.allSatisfy({ kind($0.name) == .command }),
           let last = steps.last(where: { $0.summary.contains("\n") }),
           let line = last.summary.split(separator: "\n").first.map({ $0.trimmingCharacters(in: .whitespaces) }),
           !line.isEmpty {
            return line + " +\(steps.count - 1)"
        }
        // Facts only, by consequence: what changed (naming up to two files), then what ran, then
        // what was only looked at.
        var counts: [Kind: Int] = [:]
        for step in steps { counts[kind(step.name), default: 0] += 1 }
        func n(_ count: Int, _ one: String, _ many: String) -> String { "\(count) \(count == 1 ? one : many)" }
        var parts: [String] = []
        if let c = counts[.edit] {
            var files: [String] = []
            for step in steps where kind(step.name) == .edit {
                let path = step.summary.split(separator: "\n").first.map(String.init) ?? ""
                let name = (path as NSString).lastPathComponent
                if !name.isEmpty, !files.contains(name) { files.append(name) }
            }
            parts.append((1...2).contains(files.count) ? "edited " + files.joined(separator: ", ")
                         : "edited " + n(files.isEmpty ? c : files.count, "file", "files"))
        }
        if let c = counts[.command] { parts.append("ran " + n(c, "command", "commands")) }
        let looked = (counts[.read] ?? 0) + (counts[.search] ?? 0)
        if looked > 0 {
            if parts.isEmpty && counts[.other] == nil { parts.append("explored " + n(looked, "file", "files")) }
            else {
                if let c = counts[.read] { parts.append("read " + n(c, "file", "files")) }
                if let c = counts[.search] { parts.append("searched " + n(c, "time", "times")) }
            }
        }
        if let c = counts[.other] { parts.append(n(c, "other step", "other steps")) }
        let text = parts.joined(separator: " · ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// "1 failed" when any step reported an error.
    static func failedNote(_ steps: [Step]) -> String? {
        let failed = steps.filter(\.failed).count
        return failed == 0 ? nil : "\(failed) failed"
    }

    private var symbol: String {
        steps.count == 1 && Self.kind(steps[0].name) == .command ? "apple.terminal" : "list.bullet"
    }

    /// The height shown, which follows the content's with an animation: a run folding into its
    /// summary line (as the reply arrives) glides shut instead of snapping, and the chat, which
    /// keeps its bottom still, doesn't jerk everything above it.
    @State private var height: CGFloat?
    /// The glide and clip apply while the run is live and shortly after (so folding shut still plays).
    @State private var gliding = false
    /// How far past the measured box the clip reaches. The rows hang out of the box by the pulled-in
    /// padding plus however much taller than their 28-pt row larger text makes them, so this is
    /// generous: a tight reach cut the tops and tails of letters at bigger text sizes.
    @ScaledMetric(relativeTo: .footnote) private var clipReach: CGFloat = 40

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.hit("ToolRun")
        #endif
        let content = Group {
            if running && !waiting {
                live
                    .foregroundStyle(palette.secondary)
                    .padding(.vertical, -max(0, (PlatformMetrics.controlHeight - 24) / 2))
                    // Swapped, not cross-faded: both at once made the row taller, then it snapped.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else {
                summary
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        return Group {
            if gliding || running {
                content
                    // Measured only to glide: a change of a point or less is not a state change.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { new in
                        guard let old = height else { height = new; return }
                        guard abs(old - new) > 1 else { return }
                        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) { height = new }
                    }
                    .frame(height: height, alignment: .top)
                    // The live run's negative vertical padding lets its lines hang past the measured box; a plain
                    // clip cut the newest line's descenders, so the clip reaches that far too: the clip is the
                    // box grown by that much, applied by padding out, clipping, and padding back in.
                    .padding(.vertical, clipReach)
                    .clipped()
                    .padding(.vertical, -clipReach)
            } else {
                content
            }
        }
        .task(id: running) {
            if running { gliding = true; return }
            guard gliding else { return }
            try? await Task.sleep(for: .seconds(0.5))
            gliding = false
            height = nil
        }
    }

    /// The run the agent is in: its latest steps, one line each, the newest last with a shimmer,
    /// and one output box below them. Built so the run only ever grows, never shrinks, while the
    /// agent works: the chat keeps its bottom still, so every shrink and regrowth here moved all
    /// the text above it up and down. So at most `recent` steps are listed (earlier ones count on
    /// one line), and the output box stays put between steps, showing the last output until the
    /// new step prints, at the tallest height it reached in this run.
    private static let recent = 3

    private var live: some View {
        let shown = Array(steps.suffix(Self.recent))
        let earlier = steps.count - shown.count
        let newestOutput = steps.last?.output
        let lastOutput = newestOutput ?? steps.dropLast().last(where: { $0.output != nil })?.output
        return VStack(alignment: .leading, spacing: 0) {
            if earlier > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark").font(.footnote).frame(width: 18)
                    Text(earlierSummary(earlier) ?? "\(earlier) earlier step\(earlier == 1 ? "" : "s")")
                        .font(.footnote)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28, alignment: .leading)
                .contentTransition(.numericText())
                // A few words on what the folded steps did (one line, so the run never grows by it).
                .task(id: summaryRequestKey(earlierKey(earlier))) {
                    guard summaryScenePhase == .active, earlier > 1 else { return }
                    await summaries.requestSteps(id: earlierKey(earlier),
                                                 titles: steps.prefix(earlier).map { Self.title([$0]) })
                }
            }
            ForEach(shown, id: \.id) { step in
                let newest = step.id == steps.last?.id
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
                    Text(Self.title([step]))
                        .font(newest ? .footnote.weight(.medium) : .footnote)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .shimmer(palette: palette, active: newest)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel((newest ? "Running: " : "") + Self.title([step]))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
            if let lastOutput {
                // Until the new step prints, the box keeps its size but not the last step's text:
                // under the running step, that text read as its output.
                outputBlock(lastOutput, minLines: outputLines)
                    .opacity(newestOutput == nil ? 0 : 1)
                    .overlay(alignment: .topLeading) {
                        if newestOutput == nil {
                            Text("Waiting for output…")
                                .font(.footnote)
                                .foregroundStyle(palette.secondary)
                                .padding(10)
                        }
                    }
                    .padding(.leading, 26)
                    .padding(.top, 2)
                    .transition(.opacity)
            }
        }
        .onChange(of: lastOutput.map(Self.lineCount) ?? 0, initial: true) { _, n in
            outputLines = max(outputLines, min(n, 8))
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35), value: steps.map(\.id))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35), value: outputLines)
    }

    private func earlierKey(_ earlier: Int) -> String {
        "steps|" + (steps.prefix(earlier).last?.id ?? "")
    }

    /// The newest few words written for this run's folded steps: while the next are written, the
    /// last ones stay, so the line doesn't flip back to a count.
    private func earlierSummary(_ earlier: Int) -> String? {
        for n in stride(from: earlier, through: 2, by: -1) {
            if let line = summaries.summary(for: earlierKey(n)) { return line }
        }
        return nil
    }

    private static func lineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// A tool's output: monospaced, at most 8 lines tall, scrolling for more, sticking to the end.
    /// `minLines`: at least this tall (a live run's box doesn't shrink between steps).
    private func outputBlock(_ output: String, minLines: Int = 0) -> some View {
        // Blank lines at the start of the output only push it down the box.
        let output = String(output.drop { $0 == "\n" || $0 == "\r" })
        let lines = max(Self.lineCount(output), minLines)
        return ScrollView(.vertical) {
            Text(output)
                .font(.footnote.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
        }
        // Output shorter than the box (which keeps the tallest height it reached in this run)
        // sits at the top, not at the bottom under empty space; longer output still follows
        // its end.
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
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
                        VStack(alignment: .leading, spacing: 2) {
                            (Text(title) + (Self.failedNote(steps).map { Text(" · " + $0).foregroundStyle(.red) } ?? Text("")))
                                .font(.footnote)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let digest {
                                Text(digest)
                                    .font(.footnote)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(minHeight: PlatformMetrics.controlHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(running ? "Running: \(title)" : [title, Self.failedNote(steps), digest].compactMap { $0 }.joined(separator: ". "))
            .accessibilityHint(open ? "Hides the steps" : "Shows each step")

            if open || waiting {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(steps) { step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.name).font(.footnote.weight(.semibold))
                            if !step.summary.isEmpty {
                                Text(FilePathDetector.linkified(step.summary))
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
        .task(id: digestStep.map { summaryRequestKey("\($0.id)") }) {
            guard summaryScenePhase == .active, let step = digestStep, let output = step.output else { return }
            await summaries.request(id: step.id, finished: true, name: step.name, command: step.summary, output: output)
        }
        .task(id: running || waiting ? "" : summaryRequestKey(stepsKey)) {
            guard summaryScenePhase == .active, !running, !waiting, steps.count > 1 else { return }
            await summaries.requestSteps(id: stepsKey, titles: steps.map { Self.title([$0]) })
        }
        .foregroundStyle(palette.secondary)
        // Keep the control from adding air between messages; not with the second line, which
        // makes the row taller than the control (pulling it in clipped both lines).
        .padding(.vertical, digest == nil || running || waiting ? -max(0, (PlatformMetrics.controlHeight - 24) / 2) : 0)
    }
}

/// Suggested replies above the reply bar. Tapping one fills the reply field; it never sends.
private struct ReplyChips: View {
    let chips: [String]
    @Binding var draft: String
    let palette: ChatPalette
    /// Set while Codex has a question open: a chip answers it instead of filling the draft.
    var answer: ((String) -> Void)? = nil

    @State private var picks = 0

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(chips, id: \.self) { chip in
                    Button {
                        if let answer { answer(chip) } else { draft = chip }
                        picks += 1
                    } label: {
                        Text(chip)
                            .font(.footnote)
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(palette.bubble, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reply-chip")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: picks)
    }
}

/// The phrases that fit a width, with their shuffled order and the mark's, for one run (seed).
struct WorkingPool: Equatable {
    var phrases: [String] = []
    var order: [Int] = []
    var markOrder: [Int] = []

    init() {}
    init(width: CGFloat, seed: Int) {
        phrases = WorkingRow.fitting(width)
        order = WorkingRow.order(phrases.count, seed: seed)
        markOrder = WorkingRow.order(WorkingMark.count, seed: seed &+ 1)
    }
}

/// The agent is busy: a turning spark, a playful verb that changes every few seconds under a
/// shimmer, how long it has been at it, and its own status text. Reduce Motion keeps it still.
struct WorkingRow: View {
    let agent: ChatAgent
    let detail: String?
    let palette: ChatPalette
    let since: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let phrases = WorkingPhrases.all

    /// Width the row has, so a phrase too long for it is never picked (it would truncate mid-joke).
    @State private var width: CGFloat = 0
    /// The phrases fitting `width` and their order for this run: worked out when the width, the
    /// text size or the run changes, not on every tick.
    @State private var pool = WorkingPool()
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The phrases that fit `width` alongside the mark and the elapsed time, in phrase order.
    static func fitting(_ width: CGFloat) -> [String] {
        guard width > 0 else { return phrases }
        let base = PlatformFont.preferredFont(forTextStyle: .footnote)
        let bold = PlatformFont.systemFont(ofSize: base.pointSize, weight: .semibold)
        let plain = PlatformFont.monospacedDigitSystemFont(ofSize: base.pointSize, weight: .regular)
        // Mark (about 20 pt) and its 8 pt gap, and room for the longest likely timer.
        let reserved = 28 + (" · 59m 59s" as NSString).size(withAttributes: [.font: plain]).width
        let room = width - reserved
        let fit = phrases.filter { ($0 + "…" as NSString).size(withAttributes: [.font: bold]).width <= room }
        return fit.isEmpty ? phrases.filter { $0.count <= 10 } : fit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WorkingLine(since: since, pool: pool, width: width, palette: palette)
            // What herdr-core says the agent is doing, on a line of its own under the phrase:
            // sharing the phrase's line, a long phrase squeezed it to "…" and it seemed missing.
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(2)
                    .padding(.leading, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; refreshPool() }
        .onChange(of: typeSize) { refreshPool() }
        .onChange(of: since) { refreshPool() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(agent.displayName) is working" + (detail.map { ": \($0)" } ?? ""))
    }

    private func refreshPool() {
        pool = WorkingPool(width: width, seed: Int(since.timeIntervalSince1970))
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

/// The line of the working row that changes: the mark, the phrase and the elapsed time. Its own
/// timeline ticks each second, so only this line is evaluated again, not the whole row.
private struct WorkingLine: View {
    let since: Date
    let pool: WorkingPool
    let width: CGFloat
    let palette: ChatPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            let seconds = max(0, Int(context.date.timeIntervalSince(since)))
            // A new phrase every 3 s, in an order of its own for each run.
            let step = seconds / 3
            let seed = Int(since.timeIntervalSince1970)
            let phrases = pool.phrases.isEmpty ? WorkingRow.fitting(width) : pool.phrases
            let verb = pool.phrases.isEmpty
                ? phrases[WorkingRow.order(phrases.count, seed: seed)[step % phrases.count]]
                : phrases[pool.order[step % phrases.count]]
            // The picture stays as long as its keyframes run (see `WorkingMark.pictureDuration`).
            let picture = Int(WorkingMark.pictureDuration)
            let markStep = seconds / picture
            let markOrder = pool.markOrder.isEmpty ? WorkingRow.order(WorkingMark.count, seed: seed &+ 1) : pool.markOrder
            let markIndex = markOrder[markStep % WorkingMark.count]
            let previousMark = markStep > 0 ? markOrder[(markStep - 1) % WorkingMark.count] : nil
            HStack(spacing: 8) {
                WorkingMark(index: markIndex, previous: previousMark,
                            changedAt: since.addingTimeInterval(Double(markStep * picture)), color: palette.accent)
                HStack(spacing: 0) {
                    // One phrase gives way to the next: a short crossfade with a small rise
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
                    Text(" · " + WorkingRow.elapsed(seconds))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(palette.secondary)
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The chat's way to open an image, made once. It is an environment value, which reaches every
/// view in the chat: a closure made anew each time the chat's body ran read as a changed
/// environment for all of them (every text in every row checked again, on every streamed token).
@MainActor
final class ImageOpener {
    private var made: ((PlatformImage) -> Void)?

    func action(_ viewing: Binding<ViewedImage?>) -> (PlatformImage) -> Void {
        if let made { return made }
        let action: (PlatformImage) -> Void = { viewing.wrappedValue = ViewedImage(image: $0) }
        made = action
        return action
    }
}

/// How far the bottom of the conversation is, in the steps the chat reacts to.
struct BottomDistance: Equatable {
    let near: Bool, beyond150: Bool, beyond600: Bool
    init(below: CGFloat) { near = below <= 48; beyond150 = below > 150; beyond600 = below > 600 }
}

/// Whether the chat is scrolling, kept out of `ChatView` so a change only redraws `IdleHitTesting`.
@Observable final class ScrollState {
    var scrolling = false
}

/// While the list moves, its rows don't answer the pointer.
private struct IdleHitTesting: ViewModifier {
    let state: ScrollState
    func body(content: Content) -> some View { content.allowsHitTesting(!state.scrolling) }
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
            if LayerMotion.on { layered(content) } else { animated(content) }
        }
    }

    /// The band is moved by Core Animation, off the main thread (see `LayerMotion`).
    private func layered(_ content: Content) -> some View {
        content
            .overlay {
                ShimmerBand()
                    .blendMode(.plusLighter)
                    .mask(content)
                    .allowsHitTesting(false)
            }
    }

    private func animated(_ content: Content) -> some View {
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

private extension View {
    func shimmer(palette: ChatPalette) -> some View { modifier(Shimmer(palette: palette)) }
    /// A shimmer only while `active` (the newest step of a live run).
    @ViewBuilder func shimmer(palette: ChatPalette, active: Bool) -> some View {
        if active { modifier(Shimmer(palette: palette)) } else { self }
    }
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
/// A tool call Claude's auto mode blocked, with a button that approves it and runs it again.
private struct BlockedCard: View {
    let reason: String
    let summary: String
    let description: String
    let retried: Bool
    let sending: Bool
    let enabled: Bool
    let palette: ChatPalette
    let allow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: retried ? "checkmark.shield.fill" : "hand.raised.fill")
                    .foregroundStyle(retried ? palette.secondary : Color.needsYou)
                Text(retried ? "Allowed and run again" : "Auto mode blocked this")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                if !reason.isEmpty, !retried {
                    Text(reason).font(.caption).foregroundStyle(palette.secondary).lineLimit(1)
                }
            }
            Text(summary)
                .font(.footnote.monospaced())
                .foregroundStyle(palette.secondary)
                .lineLimit(retried ? 2 : 6)
                .textSelection(.enabled)
            if !retried {
                Button(action: allow) {
                    Label(sending ? "Allowing…" : "Allow and retry", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(Color.needsYou)
                .disabled(!enabled || sending)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// The command with all whitespace removed: the menu wraps it to the terminal's width.
    static func needle(_ summary: String) -> String {
        String(summary.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// The selected row's command, printed between the first two dashed lines, is this one.
    static func shows(_ needle: String, in lines: [String]) -> Bool {
        let rules = lines.indices.filter { i in
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            return t.count > 10 && t.allSatisfy { $0 == "╌" }
        }
        guard rules.count >= 2, !needle.isEmpty else { return false }
        // Only an exact match: a cut-off command could be another one that starts the same way.
        return Self.needle(lines[(rules[0] + 1)..<rules[1]].joined()) == needle
    }
}

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

extension QuestionCard {
    /// Sends the answer: the option says "Sending…" until it shows as answered, and a light
    /// haptic confirms it went (only here, not on every tap).
    func pick(_ choice: String) {
        guard sending == nil else { return }
        sending = choice
        sent += 1
        choose(choice)
        // Not answered after a while (the send failed): the options take taps again.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            if answer == nil { sending = nil }
        }
    }

    /// "Finish and ship (Recommended)" → ("Finish and ship", true): Claude marks its pick that way.
    static func recommendation(_ option: String) -> (String, Bool) {
        let marker = "(recommended)"
        let trimmed = option.trimmingCharacters(in: .whitespaces)
        guard trimmed.lowercased().hasSuffix(marker) else { return (option, false) }
        return (String(trimmed.dropLast(marker.count)).trimmingCharacters(in: .whitespaces), true)
    }
}

/// An agent's multiple-choice question (Codex's request_user_input): tap an option to send it as
/// the reply. Once answered, it shows the reply and the options go quiet.
private struct QuestionCard: View {
    let title: String
    let options: [String]
    /// A line under each option (Claude's option descriptions), when there are any.
    var details: [String] = []
    /// A short topic label shown above the question ("Workers").
    var header = ""
    /// 1, 2, 3 like Claude's menu in the terminal; A, B, C for Codex's questions.
    var numbered = false
    let answer: String?
    let palette: ChatPalette
    let enabled: Bool
    var allowsText = false
    let choose: (String) -> Void
    @State private var response = ""
    /// The option just tapped, until the answer shows: it says "Sending…" meanwhile.
    @State private var sending: String?
    /// Counts answers sent, for the haptic.
    @State private var sent = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !header.isEmpty {
                Text(header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
            }
            Label {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(palette.text)
            } icon: {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(palette.accent)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let letter = numbered ? "\(index + 1)" : String(UnicodeScalar(UInt8(65 + min(index, 25))))
                let picked = answer.map { Self.matches($0, option: option, letter: letter) } ?? false
                let isSending = answer == nil && sending == option
                let (label, recommended) = Self.recommendation(option)
                Button { pick(option) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(letter).font(.footnote.weight(.semibold).monospaced())
                            .foregroundStyle(picked ? Color.white.opacity(0.8) : palette.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            // Centered on the title, not on its baseline: by baseline the pill's
                            // padding hung below the line and crowded the description.
                            HStack(alignment: .center, spacing: 8) {
                                Text(label).font(.callout).multilineTextAlignment(.leading)
                                if recommended {
                                    Text("Recommended")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .foregroundStyle(picked ? Color.white : palette.accent)
                                        .background((picked ? Color.white : palette.accent).opacity(0.15), in: Capsule())
                                }
                            }
                            if index < details.count, !details[index].isEmpty {
                                Text(details[index])
                                    .font(.footnote)
                                    .foregroundStyle(picked ? Color.white.opacity(0.8) : palette.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if picked {
                            Image(systemName: "checkmark")
                        } else if isSending {
                            ProgressView().controlSize(.small).accessibilityLabel("Sending")
                        }
                    }
                    .foregroundStyle(picked ? Color.white : palette.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(minHeight: PlatformMetrics.controlHeight)
                    .background(picked ? palette.accent : palette.bubble,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .disabled(answer != nil || !enabled || sending != nil)
                .opacity(answer != nil && !picked ? 0.5 : 1)
            }
            if allowsText {
                if let answer {
                    Text(answer).font(.callout).foregroundStyle(palette.secondary)
                } else {
                    Text("Or answer in your own words")
                        .font(.footnote)
                        .foregroundStyle(palette.secondary)
                        .padding(.top, 2)
                    let empty = response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Your answer", text: $response, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...5)
                            .accessibilityIdentifier("codex-question-answer")
                        Button { pick(response) } label: {
                            Image(systemName: "arrow.up")
                                .font(.callout.weight(.bold))
                                .frame(width: 30, height: 30)
                                .foregroundStyle(empty ? palette.secondary : Color.white)
                                .background(empty ? palette.bubble : palette.accent, in: Circle())
                        }
                        .buttonStyle(PressStyle())
                        .disabled(!enabled || empty || sending != nil)
                        .accessibilityLabel("Send Answer")
                        .accessibilityIdentifier("codex-question-send")
                    }
                    .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
                    .background(palette.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(12)
        .sensoryFeedback(.impact(weight: .light), trigger: sent)
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
/// After 30 s it gives up showing progress and offers Retry, whatever the reading is stuck on.
private struct ReadingSpinner: View {
    var color: Color
    var onStuck: () -> Void = {}
    var retry: (() -> Void)?
    @State private var visible = false
    @State private var stuck = false
    @State private var attempt = 0

    var body: some View {
        Group {
            if stuck {
                ContentUnavailableView {
                    Label("Can't read the conversation", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Reading it has taken over 30 seconds.")
                } actions: {
                    if let retry {
                        Button("Retry") {
                            stuck = false
                            attempt += 1
                            retry()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                ProgressView("Reading the conversation…")
                    .foregroundStyle(color)
                    .opacity(visible ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .task(id: attempt) {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeIn(duration: 0.2)) { visible = true }
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            onStuck()
            withAnimation { stuck = true }
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
    var scope: ApprovalScope? = nil
    var demo = false
    let record: (String, String) -> Void

    var body: some View {
        let claude = ChatAgent.detect(terminal) == .claude
        let auth = claude && AnswerParser.showSignedOut(in: model.textLines, status: terminal.status)
        let approval = claude && model.menuOpen && AnswerParser.showsApprovalChoices(in: model.textLines)
        if (blocked && terminal.status?.kind != "auth") || model.inLogin || auth || approval {
            AnswerCard(status: terminal.status, model: model, palette: palette, scope: scope, demo: demo) { record($0, $1) }
                .transition(transition)
        } else if model.menuOpen, terminal.status?.state == "idle" {
            MenuCard(model: model, palette: palette).transition(transition)
        } else if let offer = AlwaysAllowOffers.shared.current, offer.scope == scope {
            AlwaysAllowBanner(offer: offer, palette: palette).transition(transition)
        }
    }
}

/// A slash-command menu is open in the terminal while the agent reads as idle: its options as
/// buttons when they parse, and a Close button.
private struct MenuCard: View {
    let model: TerminalScreenModel
    let palette: ChatPalette
    @State private var closing = false
    @State private var tapped = 0

    var body: some View {
        let lines = model.textLines
        let title = AnswerParser.menuTitle(lines) ?? "A menu is open"
        let choices = AnswerParser.choices(in: Array(lines.suffix(20)))
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "list.bullet")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(2)
            Text("A menu is open in the terminal. Pick an option, or close it to chat again.")
                .font(.footnote)
                .foregroundStyle(palette.secondary)
            ForEach(choices, id: \.number) { choice in
                Button {
                    tapped += 1
                    closing = true
                    let steps = AnswerParser.steps(to: choice, in: choices)
                    Task { @MainActor in
                        defer { closing = false }
                        await model.automate {
                            // The same menu still up, or nothing: a queued tap must not land on
                            // whatever replaced it.
                            guard AnswerParser.menuOpen(model.textLines),
                                  AnswerParser.choices(in: Array(model.textLines.suffix(20))) == choices else { return }
                            let key: TerminalKey = steps < 0 ? .up : .down
                            for _ in 0..<abs(steps) {
                                model.press(key)
                                try? await Task.sleep(for: .milliseconds(40))
                            }
                            try? await Task.sleep(for: .milliseconds(80))
                            model.press(.enter)
                        }
                    }
                } label: {
                    Text("\(choice.number). \(choice.label)")
                        .font(.callout)
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(minHeight: PlatformMetrics.controlHeight)
                        .background(palette.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressStyle())
                .disabled(closing)
            }
            Button {
                tapped += 1
                closing = true
                Task { @MainActor in
                    _ = await model.closeMenu()
                    closing = false
                }
            } label: {
                Text("Close")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.onAccent)
                    .frame(maxWidth: .infinity, minHeight: PlatformMetrics.controlHeight)
                    .background(palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(PressStyle())
            .disabled(closing)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light), trigger: tapped)
    }
}

/// The ⋯ menu with what it reads from the screen and the feed.
private struct MoreMenuSlot: View {
    let agent: ChatAgent
    let feed: ChatFeed
    let model: TerminalScreenModel
    let hasInfo: Bool
    let canSetMode: Bool
    let lifecycle: AgentLifecycle
    let canManage: Bool
    let end: () -> Void
    let restart: () -> Void
    @Binding var choosingMode: Bool
    @Binding var sendError: String?
    let search: () -> Void
    let usage: () -> Void
    let info: () -> Void

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.hit("MoreMenuSlot")
        #endif
        // Compared by what it shows: rebuilt on every screen change (a working Codex redraws its
        // timer each second), an open menu closed before you could pick anything.
        MoreMenu(
            agent: agent, hasUsage: feed.usage != nil || agent == .claude, hasInfo: hasInfo,
            currentMode: PermissionModes.current(agent, in: model.textLines, saved: feed.usage?.mode),
            saved: feed.usage?.mode, canSetMode: canSetMode, canManage: canManage,
            search: search, usage: usage, permissions: { choosingMode = true }, info: info,
            exporting: { ConversationExportButtons(feed: feed, agent: agent) },
            restart: { lifecycle.confirming = .restart }, end: { lifecycle.confirming = .end })
        .equatable()
        .agentLifecycleDialogs(lifecycle, name: agent.displayName, end: end, restart: restart)
        .confirmationDialog("Permissions", isPresented: $choosingMode, titleVisibility: .visible) {
            let current = PermissionModes.current(agent, in: model.textLines, saved: feed.usage?.mode)
            ForEach(PermissionModes.modes(agent), id: \.self) { mode in
                Button(mode == current ? "\(mode) ✓" : mode) {
                    Task {
                        if let problem = await PermissionModes.set(mode, agent: agent, model: model, saved: feed.usage?.mode) {
                            sendError = problem
                        }
                    }
                }
            }
        }
    }
}

/// The agent's permission mode, current one checked; switching goes through the terminal.
private struct MoreMenu: View, Equatable {
    let agent: ChatAgent
    let hasUsage: Bool
    let hasInfo: Bool
    let currentMode: String?
    let saved: String?
    let canSetMode: Bool
    let canManage: Bool
    let search: () -> Void
    let usage: () -> Void
    let permissions: () -> Void
    let info: () -> Void
    let exporting: () -> ConversationExportButtons
    let restart: () -> Void
    let end: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.agent == b.agent && a.hasUsage == b.hasUsage && a.hasInfo == b.hasInfo
            && a.currentMode == b.currentMode && a.saved == b.saved && a.canSetMode == b.canSetMode
            && a.canManage == b.canManage
    }

    var body: some View {
        Menu {
            Button("Search", systemImage: "magnifyingglass", action: search)
            // On the Mac the inspector shows usage and sets the permission mode.
            #if os(iOS)
            if hasUsage {
                Button("Usage", systemImage: "gauge.with.dots.needle.50percent", action: usage)
            }
            // A dialog, not a submenu: a submenu closed whenever the toolbar updated, and that's
            // every second while an agent works.
            Button("Permissions" + (currentMode.map { " · \($0)" } ?? ""), systemImage: "lock.shield", action: permissions)
                .disabled(!canSetMode)
            #endif
            if hasInfo {
                Button("Info", systemImage: "info.circle", action: info)
            }
            exporting()
            if canManage {
                Divider()
                if agent != .antigravity {
                    Button("Restart", systemImage: "arrow.clockwise", action: restart)
                }
                Button("End Session", systemImage: "stop.circle", role: .destructive, action: end)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        // One glyph in the toolbar: the Mac's menu chevron beside it read as a second control.
        .menuIndicator(.hidden)
    }
}

/// "Copy conversation as Markdown" and "Share conversation…". The text is built when it's used,
/// not when the menu draws.
private struct ConversationExportButtons: View {
    let feed: ChatFeed
    let agent: ChatAgent

    var body: some View {
        Button("Copy Conversation as Markdown", systemImage: "doc.on.doc") {
            Pasteboard.copy(TranscriptExport.markdown(items: feed.items, agent: agent.displayName))
        }
        ShareLink(
            "Share Conversation…",
            item: TranscriptShare { [feed, name = agent.displayName] in
                TranscriptExport.markdown(items: feed.items, agent: name)
            },
            preview: SharePreview("Conversation with \(agent.displayName)"))
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

/// A crossfade with a small rise, for one phrase replacing another. No blur: a blur re-rasterizes
/// the text on every frame of the change.
private struct PhraseChange: ViewModifier {
    let shown: Bool
    let rise: CGFloat
    func body(content: Content) -> some View {
        content.opacity(shown ? 1 : 0).offset(y: shown ? 0 : rise)
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
    private static let inCache = NSCache<NSString, NSArray>()
    private static let ranCache = NSCache<NSString, NSArray>()

    /// `in(_:)`, remembered per text: the context menus ask on every body.
    static func cachedIn(_ text: String) -> [String] {
        let key = text as NSString
        if let hit = inCache.object(forKey: key) as? [String] { return hit }
        let value = Self.in(text)
        inCache.setObject(value as NSArray, forKey: key)
        return value
    }

    /// `ran(_:)`, remembered per list of steps.
    static func cachedRan(_ steps: [(name: String, summary: String)]) -> [String] {
        let key = steps.map { "\($0.name)\u{1}\($0.summary)" }.joined(separator: "\u{2}") as NSString
        if let hit = ranCache.object(forKey: key) as? [String] { return hit }
        let value = ran(steps)
        ranCache.setObject(value as NSArray, forKey: key)
        return value
    }

    static func `in`(_ text: String) -> [String] {
        var out: [String] = []
        func add(_ s: String) {
            var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // Written for an agent's shell mode (`! git push`): the command is what follows the
            // `!`. Run adds its own, and in a terminal `! cmd` means "negate cmd's result".
            if s.hasPrefix("!"), !s.contains("\n") { s = s.dropFirst().trimmingCharacters(in: .whitespaces) }
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

    /// The commands a run of tool steps ran (shell steps; the command is the summary's last line,
    /// below the agent's description of it).
    static func ran(_ steps: [(name: String, summary: String)]) -> [String] {
        let shells: Set<String> = ["bash", "exec", "shell", "run_command", "local_shell", "exec_command"]
        var out: [String] = []
        for step in steps where shells.contains(step.name.lowercased()) {
            let command = step.summary.split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !command.isEmpty, !out.contains(command) { out.append(command) }
        }
        return Array(out.suffix(8))
    }

    /// Whether Run can send it: one line, and not shortened on the way here.
    static func runnable(_ command: String) -> Bool {
        !command.contains("\n") && !command.hasSuffix("…") && !command.isEmpty
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
                .macPlainButton()
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
    /// Asks the app to open a terminal (userInfo: "host" UUID, "address" String).
    static let openTerminal = Notification.Name("bergr.openTerminal")

    /// Whether a terminal's own program is a shell (so a quit agent leaves a prompt to type into).
    static func isShell(_ argv: [String]) -> Bool {
        guard let first = argv.first else { return true }
        // `sh -c '… exec claude'` (a restarted terminal) runs a command, not an interactive shell.
        if argv.dropFirst().contains(where: { ["-c", "/c", "-command", "-Command"].contains($0) }) { return false }
        let name = (first.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? first).lowercased()
            .replacingOccurrences(of: ".exe", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "powershell", "cmd", "elvish", "xonsh"]
            .contains(name)
    }

    /// A Claude started from inside another Claude's session inherits CLAUDE_CODE_CHILD_SESSION and
    /// saves no transcript, which leaves the chat with nothing to read. A restart drops it.
    static func typedLine(_ command: String, windows: Bool) -> String {
        windows ? command : "env -u CLAUDE_CODE_CHILD_SESSION " + command
    }

    /// The command as a new terminal's program: Claude's usual install folders first on PATH.
    static func directLine(_ command: String) -> String {
        #"unset CLAUDE_CODE_CHILD_SESSION; PATH="$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin:$PATH"; exec "# + command
    }

    static func make(argv: [String], conversation: String) -> String {
        arguments(argv: argv, conversation: conversation).map(quote).joined(separator: " ")
    }

    /// The program and arguments, unquoted (a Windows restart runs them without a shell).
    static func arguments(argv: [String], conversation: String) -> [String] {
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
        return ["claude"] + args + ["--resume", conversation]
    }

    static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// A row arriving: it is in its place from the first frame (nothing else moves for it), and
/// fades in while rising a few points, drawn only, so the list's layout never animates.
private struct ArriveIn: ViewModifier {
    let active: Bool
    var rise = true
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let waiting = active && !landed
        content
            .opacity(waiting ? 0 : 1)
            .offset(y: waiting && rise && !reduceMotion ? 10 : 0)
            .onAppear {
                guard active, !landed else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35)) { landed = true }
            }
    }
}

private extension View {
    /// The Mac's chat table keeps its rows clear of the bars over it: their heights, in whole points.
    @ViewBuilder func macBarHeight(_ changed: @escaping (CGFloat) -> Void) -> some View {
        #if os(macOS)
        onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { changed($0) }
        #else
        self
        #endif
    }
}

/// Its content's reads of observable state run this view's body, not its parent's.
struct Isolated<Content: View>: View {
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View { content() }
}

/// The chat's row stack: eager everywhere (see the comment where it's used). Lazy on the Mac
/// bounced on opening a chat: rows realized near the bottom changed the estimated height, the
/// bottom anchor moved, more rows realized… The Mac shows fewer rows at a time instead (`rowPage`).
typealias ChatRows<Content: View> = VStack<Content>


/// A sideways drag slides the messages and shows when each was written, in the space it opens.
struct MessageTimeReveal: ViewModifier {
    /// The drag's pull. Only `Slide` reads it: the chat and its rows don't redraw while dragging.
    @MainActor @Observable final class Pull { var offset: CGFloat = 0 }

    static let width: CGFloat = 76
    let time: Date?

    /// Leftward only (like Messages; times show on the right), and only after a deliberate
    /// 30-pt pull: the first stretch does nothing, then it follows the finger, then resists.
    static let deadZone: CGFloat = 30

    static func clamp(_ dx: CGFloat) -> CGFloat {
        let pulled = max(0, -dx - deadZone)
        return -(pulled <= width ? pulled : width + (pulled - width) * 0.15)
    }

    static func label(_ time: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(time, inSameDayAs: now) { return time.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: time),
                                              to: calendar.startOfDay(for: now)).day, days < 7 {
            return time.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return time.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The time on both sides, outside the row: the slide brings one into view. The row takes the
    /// full width first, so the times sit past the screen's edges and not just past a short row's.
    @ViewBuilder func body(content: Content) -> some View {
        #if os(macOS)
        // No sideways drag on the Mac: and stretching the row there centered short messages.
        content
        #else
        revealing(content)
        #endif
    }

    private func revealing(_ content: Content) -> some View {
        content.frame(maxWidth: time == nil ? nil : .infinity, alignment: .leading).overlay {
            if let time {
                let text = Self.label(time)
                HStack(spacing: 0) {
                    Self.stamp(text, alignment: .trailing).offset(x: -Self.width)
                    Spacer(minLength: 0)
                    Self.stamp(text, alignment: .leading).offset(x: Self.width)
                }
                .accessibilityHidden(true)
            }
        }
    }

    private static func stamp(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(width: width - 8, alignment: alignment)
    }

    /// Moves the whole list with the drag and clips the times waiting outside it.
    /// The view's width, and all the height there is.
    struct SidesOnly: Shape {
        func path(in rect: CGRect) -> Path { Path(rect.insetBy(dx: 0, dy: -10_000)) }
    }

    struct Slide: ViewModifier {
        let pull: Pull
        func body(content: Content) -> some View {
            content
                .offset(x: pull.offset)
                // Clips only the sides, where the times wait: never the rows' tops and bottoms. A
                // rectangular clip, not a mask: a mask had the whole chat drawn offscreen on every
                // scroll frame.
                .clipShape(SidesOnly())
        }
    }
}
