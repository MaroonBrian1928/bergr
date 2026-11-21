// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation
import HerdrKit
import Observation

/// One attached terminal: the herdr stream feeding a libghostty-vt emulator,
/// and input going back the other way.
@Observable
final class TerminalScreenModel {
    enum Phase: Equatable {
        case attaching
        case live
        case ended(String)
        case failed(String)
    }

    private(set) var phase: Phase = .attaching
    /// The latest screen; the view redraws when it changes.
    private(set) var frame: ScreenFrame = .empty
    /// The screen's text, one string per row, and whether it shows a login prompt: worked out
    /// once per frame and set only when they change, so the chat's answer bar and permissions
    /// menu don't each rebuild them (or redraw) on every frame.
    private(set) var textLines: [String] = []
    private(set) var inLogin = false
    /// Typed input a dropped channel left unconfirmed (it may or may not have arrived): the
    /// screen offers Resend or Discard; nothing is resent on its own.
    private(set) var ambiguousInput = 0
    private(set) var ambiguousPreview = ""
    /// Speculative local echo to draw over the screen (opt-in, slow links only).
    private(set) var prediction: EchoPredictor.Prediction?
    /// What was typed here on the current line since the last Return; nil once it can't be known
    /// (arrows, Tab, Escape move or change the line in ways we don't follow).
    @ObservationIgnored private(set) var typedLine: String? = ""
    @ObservationIgnored private var journal = InputJournal()
    @ObservationIgnored private var latency = InputLatency()
    @ObservationIgnored private var predictor = EchoPredictor()
    @ObservationIgnored private var predictionTick: Task<Void, Never>?
    @ObservationIgnored private var statsAt: ContinuousClock.Instant?
    /// Up by one for every channel and every stop: a write started on an older one isn't journaled.
    @ObservationIgnored private var channelGeneration = 0
    /// Soft-keyboard Ctrl: applies to the next key.
    var controlLatched = false
    /// Scrolled up into history (new output does not move the view).
    private(set) var scrolledBack = false
    /// Whether the software keyboard should be up; the canvas keeps it in sync.
    var wantsKeyboard = false
    /// Attached as an observer: watching at the size another viewer set, without resizing the
    /// terminal. The core ignores an observer's typing, so typing attaches again as a viewer.
    private(set) var watching = false

    private var vt: VirtualTerminal?
    private var attached: AttachedTerminal?
    /// When the current channel attached: a reconnect right after it is the same comeback.
    private var attachedAt: Date?
    private var pump: Task<Void, Never>?
    private var pumpConnectionRevision: UInt64?
    /// The frame waiting to be rendered, if one is scheduled.
    private var renderTask: Task<Void, Never>?
    /// What this view would like (fits its bounds); sent whenever we act.
    private var preferredSize: (cols: Int, rows: Int)?
    private var session: HostSession?
    private var address: String?
    /// A cell's size in pixels at our font, for the size reports programs can ask for (mode 2048).
    var cellPixels: (width: Int, height: Int) = (0, 0) {
        didSet { vt?.cellPixels = cellPixels }
    }
    /// Typed while (re)attaching, e.g. the keys that ended watching; sent once attached.
    private var pendingInput: [Data] = []
    /// Whether this channel last told the core we have focus. Programs that asked for focus
    /// reports (lazygit highlights its focused panel) otherwise keep the focus-out they got when
    /// the desktop window lost focus, also while we type or tap.
    private var reportedFocus = false

    /// The colors to draw with; changing it recolors the live screen (or, before there is one,
    /// the empty screen shown while attaching).
    var theme: TerminalTheme {
        didSet {
            guard theme != oldValue else { return }
            guard let vt else { return frame = Self.blank(theme) }
            Self.apply(theme, to: vt)
            renderNow()
        }
    }

    /// Pass the theme it will show: the empty screen while attaching is drawn in its colors.
    init(theme: TerminalTheme) {
        self.theme = theme
        frame = Self.blank(theme)
    }

    /// No content yet, in the theme's colors (not the dark default, which flashed in light mode).
    private static func blank(_ theme: TerminalTheme) -> ScreenFrame {
        var frame = ScreenFrame.empty
        frame.foreground = theme.foregroundRGB
        frame.background = theme.backgroundRGB
        return frame
    }

    private static func apply(_ theme: TerminalTheme, to vt: VirtualTerminal) {
        vt.setDefaultColors(foreground: theme.foregroundRGB, background: theme.backgroundRGB, cursor: theme.cursorRGB)
        vt.setPalette(theme.ansiRGB)
    }

    /// Starts once the view knows how many cells fit; `watch` attaches as an observer.
    func start(session: HostSession, address: String, cols: Int, rows: Int, watch: Bool = false) {
        preferredSize = (cols, rows)
        guard pump == nil else { return }
        self.session = session
        self.address = address
        watching = watch
        phase = .attaching
        pumpConnectionRevision = session.connectionRevision
        pump = Task { await run() }
    }

    /// Whether it has been started (attached once), so it can attach again.
    var started: Bool { session != nil }

    /// Attaches again (a channel that died quietly, e.g. after the app was in the background,
    /// swallows input without an error). Input sent meanwhile waits and goes once attached.
    func reconnect() {
        guard session != nil else { return }
        // Coming back fires several of these together (the app turning active, the line coming
        // back, the screen reappearing). Each one closed the channel the one before had just
        // opened, and a key sent in between went out on a channel being closed: one attach is
        // enough. Already attaching, or attached a moment ago: keep it.
        if pump != nil, pumpConnectionRevision == session?.connectionRevision {
            if attached == nil { return }
            if let at = attachedAt, Date.now.timeIntervalSince(at) < 3 { return }
        }
        // Attaching again because the channel may have died: what it never confirmed is in doubt.
        channelEnded()
        stop()
        phase = .attaching
        pumpConnectionRevision = session?.connectionRevision
        pump = Task { await run() }
    }

    func stop() {
        // Leaving on purpose (navigating away, watching instead): no "may not have arrived".
        channelGeneration += 1
        journal.forgetPending()
        predictor.reset()
        if prediction != nil { prediction = nil }
        pump?.cancel()
        pump = nil
        let attached = self.attached
        self.attached = nil
        attachedAt = nil
        Task { await attached?.detach() }
    }

    /// Switches between watching and being a viewer. A channel can't change its kind, so this
    /// attaches again; the old screen stays up until the new one's first paint.
    func setWatching(_ watch: Bool) {
        guard watch != watching else { return }
        watching = watch
        // Another viewer may change the line meanwhile: what we typed no longer says what's there.
        typedLine = nil
        // Watching means not typing: put the keyboard away (bringing it back takes over).
        if watch { wantsKeyboard = false }
        guard pump != nil, phase == .live else { return }
        stop()
        pump = Task { await run() }
    }

    /// Lines of earlier output to ask for when attaching, so there is something to scroll back to.
    /// How much history to ask for: a little for a terminal hidden under a chat (switching to it
    /// shouldn't mean attaching again, which blanks it), and on an expensive connection.
    nonisolated static func historyLines(shown: Bool, expensive: Bool) -> Int {
        shown && !expensive ? 1000 : 200
    }

    private func run() async {
        guard let session, let address, let size = preferredSize else { return }
        let observe = watching
        let history = Self.historyLines(shown: drawing, expensive: NetworkWatcher.shared.isExpensive)
        do {
            // Attaching as a viewer makes us the active one: the core resizes the terminal to our
            // size. An observer leaves it at the size the active viewer (or nobody) set.
            let attached = try await session.attach(
                address: address, cols: size.cols, rows: size.rows, history: history, observe: observe,
                display: theme.displayFacts)
            guard !Task.isCancelled else { return await attached.detach() }
            self.attached = attached
            channelGeneration += 1
            // This channel's generation, before any await: a stop() meanwhile makes it stale.
            let generation = channelGeneration
            attachedAt = .now
            reportedFocus = false
            let vt = try VirtualTerminal(
                cols: max(attached.terminal.cols, 1), rows: max(attached.terminal.rows, 1))
            Self.apply(theme, to: vt)
            vt.cellPixels = cellPixels
            self.vt = vt
            scrolledBack = false
            phase = .live
            if !observe {
                // The grid may have changed while attaching (taking over brings up the keyboard):
                // claim the size we want now, or the terminal stays at the one we attached with.
                if let now = preferredSize, now.cols != size.cols || now.rows != size.rows { claimSize() }
                // Taking over by bringing up the keyboard, typing or tapping: we have focus. (The
                // keyboard's focus change came while watching, and a new channel starts without.)
                if wantsKeyboard || !pendingInput.isEmpty {
                    reportedFocus = true
                    try? await attached.focus(true)
                }
                for data in pendingInput { await write(data, to: attached, generation: generation) }
            }
            pendingInput.removeAll()
            for try await chunk in attached.output {
                let now = ContinuousClock.now
                journal.outputArrived(at: now)
                latency.outputArrived(at: now)
                latency.received(bytes: chunk.count)
                vt.write(chunk)
                await attached.consumed(bytes: chunk.count)
                // The first paint turns mode 2048 back on, which answers with our size: that's
                // how a Textual app learns the size we attached with.
                let replies = vt.takeReplies()
                if !replies.isEmpty { try? await attached.sendAutomatic(replies) }
                scheduleRender()
            }
            if !Task.isCancelled { phase = .ended("Detached.") }
        } catch is CancellationError {
        } catch let end as StreamEnd {
            if !Task.isCancelled { phase = .ended(end.localizedDescription) }
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
        if !Task.isCancelled {
            channelEnded()
            // The channel is gone: forget it, so the next thing sent attaches again first
            // instead of going into a dead channel.
            attached = nil
            pump = nil
            renderNow()
        }
    }

    // MARK: Size

    /// The terminal's real size changed (another viewer took over, or our resize applied).
    func remoteSizeChanged(cols: Int, rows: Int) {
        guard let vt, cols > 0, rows > 0, cols != vt.cols || rows != vt.rows else { return }
        vt.resize(cols: cols, rows: rows)
        sendReplies()
        renderNow()
    }

    /// The view's grid changed (rotation, fold, font size).
    func viewSizeChanged(cols: Int, rows: Int) {
        guard preferredSize.map({ $0.cols != cols || $0.rows != rows }) ?? true else { return }
        preferredSize = (cols, rows)
        claimSize()
    }

    /// Makes our size the terminal's size: resizing counts as activity (not while watching).
    private func claimSize() {
        guard !watching, let attached, let size = preferredSize else { return }
        vt?.resize(cols: size.cols, rows: size.rows)
        // With mode 2048 on, the resize queued a size report: after the RESIZE it describes.
        let replies = vt?.takeReplies() ?? Data()
        renderNow()
        Task {
            try? await attached.resize(cols: size.cols, rows: size.rows)
            if !replies.isEmpty { try? await attached.sendAutomatic(replies) }
        }
    }

    /// Whether another viewer currently sets a different size than ours.
    var sizeOwnedElsewhere: Bool {
        guard let vt, let size = preferredSize else { return false }
        return vt.cols != size.cols || vt.rows != size.rows
    }

    // MARK: Input

    private var automationTail: Task<Void, Never>?

    /// Runs one automated key sequence after the ones started before it have finished.
    /// Automated typing under way (a chat reply being delivered): the typed line is its, not the person's.
    @ObservationIgnored private var automating = 0

    func automate(_ steps: @escaping @MainActor () async -> Void) async {
        automating += 1
        defer { automating -= 1 }
        #if os(macOS)
        if let session, let address {
            await session.automate(address: address, steps)
            return
        }
        #endif
        let previous = automationTail
        let task = Task { @MainActor in
            await previous?.value
            await steps()
        }
        automationTail = task
        await task.value
    }

    func type(_ text: String) {
        if text == "\n" || text == "\r" {
            press(.enter)
            return
        }
        if controlLatched, text.count == 1, let c = text.first, c.isLetter || "[]\\@^_ ".contains(c) {
            // ^U and ^C leave an empty line; any other control key, we can't tell.
            typedLine = "uUcC".contains(c) ? "" : nil
            controlLatched = false
            press(c == " " ? .space : .letter(c), modifiers: .control, text: nil)
            return
        }
        predict(text)
        // Followed only while each character is one code point (one Backspace each); else unknown.
        if Self.trackable(text) {
            typedLine = typedLine.map { $0 + text }
        } else {
            typedLine = nil
        }
        send(Data(text.utf8))
    }

    func press(_ key: TerminalKey, modifiers: KeyModifiers = [], text: String? = nil) {
        guard let vt else { return }
        var modifiers = modifiers
        if controlLatched {
            modifiers.insert(.control)
            controlLatched = false
        }
        switch key {
        case .enter: typedLine = ""
        case .backspace where modifiers.isEmpty: typedLine = typedLine.map { String($0.dropLast()) }
        case .space where modifiers.isEmpty: typedLine = typedLine.map { $0 + " " }
        default: typedLine = modifiers.contains(.control) && [TerminalKey.letter("u"), .letter("c")].contains(key) ? "" : nil
        }
        // Any key but a plain character ends a prediction; Return also lifts a suspended one.
        predict(key == .enter ? "\r" : "\u{7f}")
        send(vt.encode(key, modifiers: modifiers, text: text))
    }

    func paste(_ text: String) {
        guard let vt, !text.isEmpty else { return }
        predict("\u{7f}")
        typedLine = Self.trackable(text) ? typedLine.map { $0 + text } : nil
        // Bracketed paste keeps shells and editors from running pasted lines one by one,
        // but only programs that turned it on understand the markers.
        if vt.bracketedPaste {
            send(Data("\u{1b}[200~".utf8) + Data(text.utf8) + Data("\u{1b}[201~".utf8))
        } else {
            send(Data(text.replacingOccurrences(of: "\n", with: "\r").utf8))
        }
    }

    func focusChanged(_ focused: Bool) {
        // The keyboard coming up means typing: stop watching.
        if focused && watching { return setWatching(false) }
        guard let attached else { return }
        if focused && sizeOwnedElsewhere { claimSize() }
        reportedFocus = focused
        Task { try? await attached.focus(focused) }
    }

    /// Passes on what the emulator answered by itself (see `VirtualTerminal.takeReplies()`).
    private func sendReplies() {
        guard let attached, let replies = vt?.takeReplies(), !replies.isEmpty else { return }
        Task { try? await attached.sendAutomatic(replies) }
    }

    @ObservationIgnored private var lastInput: ContinuousClock.Instant?

    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        // The first key after a pause is when a dead line matters most: check it now.
        let now = ContinuousClock.now
        if lastInput.map({ now - $0 > .seconds(5) }) ?? true { session?.checkLine() }
        lastInput = now
        // Typing while watching takes over: attach as a viewer, then send what was typed.
        if watching {
            pendingInput.append(data)
            return setWatching(false)
        }
        guard let attached else {
            // Attaching: it goes once attached. The channel ended or failed: attach again first.
            if pump != nil || session != nil { pendingInput.append(data) }
            if pump == nil, session != nil { pump = Task { await run() } }
            return
        }
        // Typing makes us the active viewer again; show the live screen.
        if scrolledBack { scroll(toBottom: true) }
        if sizeOwnedElsewhere { claimSize() }
        // Typing or tapping without the keyboard up (a click in lazygit) focuses, like clicking
        // a window does; in the same task, so the focus report arrives first.
        let focusFirst = !reportedFocus
        reportedFocus = true
        let generation = channelGeneration
        Task {
            if focusFirst { try? await attached.focus(true) }
            await write(data, to: attached, generation: generation)
        }
    }

    // MARK: Confirmations, latency, prediction

    /// Sends typed input and records it: confirmed once the write returns and output follows.
    private func write(_ data: Data, to attached: AttachedTerminal, generation: Int) async {
        // The channel it was typed for is gone (left on purpose, or replaced): send, don't journal.
        guard generation == channelGeneration else {
            try? await attached.send(data)
            return
        }
        let now = ContinuousClock.now
        let seq = journal.sent(data, at: now)
        latency.sent(at: now)
        do {
            try await attached.send(data)
            if generation == channelGeneration { journal.written(seq) }
        } catch {
            guard generation == channelGeneration else { return }
            journal.failed(seq)
            publishAmbiguous()
        }
    }

    /// The channel ended: what it never confirmed becomes ambiguous; predictions go.
    private func channelEnded() {
        journal.channelEnded()
        publishAmbiguous()
        predictor.reset()
        if prediction != nil { prediction = nil }
    }

    /// One character per cell (a blank for an empty or continuation cell), so columns line up.
    nonisolated static func cellText(_ cells: [ScreenCell]) -> String {
        String(cells.map { $0.text.first ?? " " })
    }

    private func publishAmbiguous() {
        if journal.ambiguousCount != ambiguousInput { ambiguousInput = journal.ambiguousCount }
        let preview = journal.ambiguousPreview
        if preview != ambiguousPreview { ambiguousPreview = preview }
    }

    /// Takes back what was typed on the current line and not sent (the person switched to the chat,
    /// whose reply would otherwise be typed after it): erases it with one Backspace per character
    /// and returns it, for the chat's draft. Nil when nothing is pending or the line isn't known.
    func takeTypedLine() -> String? {
        // Not while a chat reply is being typed, and not while watching (someone else's line).
        guard automating == 0, !watching, let line = typedLine, !line.isEmpty else { return nil }
        typedLine = ""
        guard let vt, attached != nil else {
            // Not attached yet: it's still waiting here, unsent. Take it off the end of the queue
            // (earlier queued lines stay); when it can't be found as typed, queue the erasing instead.
            Self.dropTail(Data(line.utf8), from: &pendingInput, orAppend: Data(repeating: 0x7f, count: line.count))
            return line
        }
        let backspace = vt.encode(.backspace, modifiers: [], text: nil)
        send(Data((0..<line.count).flatMap { _ in backspace }))
        return line
    }

    /// Removes `tail` from the end of the queued chunks when they end with exactly it; otherwise
    /// appends `fallback` (Backspaces) to undo it once sent.
    nonisolated static func dropTail(_ tail: Data, from queue: inout [Data], orAppend fallback: Data) {
        let all = queue.reduce(into: Data()) { $0.append($1) }
        guard !tail.isEmpty, all.count >= tail.count, all.suffix(tail.count) == tail else {
            queue.append(fallback)
            return
        }
        queue = [Data(all.prefix(all.count - tail.count))].filter { !$0.isEmpty }
    }

    /// Plain text whose characters are each one printable code point: one Backspace erases each.
    nonisolated static func trackable(_ text: String) -> Bool {
        text.allSatisfy { c in
            c.unicodeScalars.count == 1
                && c.unicodeScalars.allSatisfy { $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value) }
        }
    }

    /// Sends again what a dropped channel may have lost (the user chose to).
    func resendAmbiguous() {
        let data = journal.takeAmbiguous()
        publishAmbiguous()
        send(data)
    }

    func discardAmbiguous() {
        journal.discardAmbiguous()
        publishAmbiguous()
    }

    private func predict(_ text: String) {
        guard let vt else { return }
        let enabled = UserDefaults.standard.bool(forKey: EchoPredictor.settingKey)
        predictor.typed(text, enabled: enabled, latency: latency.median, alternateScreen: vt.isAlternateScreen,
                        cursor: frame.cursor.map { ($0.x, $0.y) }, cols: vt.cols, now: .now)
        showPrediction()
    }

    private func showPrediction() {
        if predictor.shown != prediction { prediction = predictor.shown }
        // An unconfirmed prediction times out even with no new output.
        predictionTick?.cancel()
        guard predictor.shown != nil else { return }
        predictionTick = Task { @MainActor [weak self] in
            try? await Task.sleep(for: EchoPredictor.confirmWithin + .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.predictor.tick(now: .now)
            self.showPrediction()
        }
    }

    /// Latency summary for Diagnostics, at most once a second.
    private func reportStats() {
        let now = ContinuousClock.now
        if let at = statsAt, now - at < .seconds(1) { return }
        statsAt = now
        guard let session, let address, !latency.samples.isEmpty else { return }
        let name = session.host.name.isEmpty ? session.host.target.host : session.host.name
        TerminalStats.shared.update(key: "\(session.host.id.uuidString)|\(address)",
                                    label: "\(name) \(address)", latency: latency)
    }

    // MARK: Scrolling

    /// A scroll gesture over a cell: to the program (mouse wheel / arrows) or our history.
    /// Watching, only our history scrolls, also under mouse-using programs like coding agents:
    /// sending to the program would take over. (A full-screen program has no history to scroll.)
    func scroll(lines: Int, column: Int, row: Int) {
        guard let vt, lines != 0 else { return }
        if watching {
            guard !vt.isAlternateScreen else { return }
            vt.scroll(by: lines)
            scrolledBack = true
            return renderNow()
        }
        switch vt.wheel(lines: lines, column: column, row: row) {
        case .scrolledLocally:
            scrolledBack = true
            renderNow()
        case .send(let data):
            send(data)
        }
    }

    func scroll(toBottom: Bool) {
        vt?.scroll(by: nil)
        scrolledBack = false
        renderNow()
    }

    // MARK: Find

    /// The matches of the current search, oldest first, and the one shown (highlighted).
    private(set) var findMatches: [TerminalSearch.Match] = []
    private(set) var findIndex: Int?
    /// The search text; set it with `find(_:)`.
    private(set) var findQuery = ""

    /// "3 of 12", "No matches", or nothing for a blank query.
    var findSummary: String {
        guard !findQuery.isEmpty else { return "" }
        guard let findIndex else { return "No matches" }
        return "\(findIndex + 1) of \(findMatches.count)"
    }

    /// Searches the scrollback and screen for `query` (ignoring case) and shows the first match
    /// at or after the top of what is on screen.
    func find(_ query: String) {
        findQuery = query
        findMatches = []
        findIndex = nil
        guard let vt, !query.isEmpty else { return clearFindHighlight() }
        let snapshot = vt.textSnapshot()
        findMatches = TerminalSearch.matches(for: query, in: snapshot.lines)
        findIndex = TerminalSearch.firstMatch(atOrAfter: vt.viewportTopRow, in: findMatches)
        showCurrentMatch(in: snapshot.lines)
    }

    /// Moves to the next or previous match, wrapping around. Looks again first, so output that
    /// arrived since is found too.
    func findStep(forward: Bool) {
        guard let vt, !findQuery.isEmpty else { return }
        let snapshot = vt.textSnapshot()
        let previous = findIndex.flatMap { findMatches.indices.contains($0) ? findMatches[$0] : nil }
        findMatches = TerminalSearch.matches(for: findQuery, in: snapshot.lines)
        let current = previous.flatMap { findMatches.firstIndex(of: $0) }
        findIndex = TerminalSearch.step(from: current, count: findMatches.count, forward: forward)
        showCurrentMatch(in: snapshot.lines)
    }

    /// Ends the search and drops the highlight.
    func endFind() {
        findQuery = ""
        findMatches = []
        findIndex = nil
        clearFindHighlight()
    }

    private func clearFindHighlight() {
        vt?.clearSelection()
        renderNow()
    }

    private func showCurrentMatch(in lines: [String]) {
        guard let vt, let findIndex, findMatches.indices.contains(findIndex) else { return clearFindHighlight() }
        let match = findMatches[findIndex]
        let line = lines[match.row]
        let first = TerminalSearch.column(ofCharacter: match.start, in: line)
        let end = TerminalSearch.column(ofCharacter: match.start + match.length, in: line)
        vt.scroll(toRow: match.row - vt.rows / 2)
        vt.select(row: match.row, columns: first...max(first, end - 1))
        renderNow()
        scrolledBack = !(frame.scrollbar?.atBottom ?? true)
    }

    /// Scrolls to the previous or next shell prompt (the shell's own OSC 133 marks when it sends
    /// them, else lines that look like one). Returns false when there is none that way.
    @discardableResult
    func jumpToPrompt(forward: Bool) -> Bool {
        guard let vt else { return false }
        let snapshot = vt.textSnapshot()
        let rows = PromptDetector.promptRows(lines: snapshot.lines, marked: snapshot.markedPromptRows)
        guard let row = PromptDetector.jump(from: vt.viewportTopRow, rows: rows, forward: forward) else { return false }
        vt.scroll(toRow: row)
        renderNow()
        scrolledBack = !(frame.scrollbar?.atBottom ?? true)
        return true
    }

    // MARK: Taps

    enum TapResult {
        /// Nothing else wanted the tap: bring up the keyboard.
        case unhandled
        case handled
        case link(URL)
    }

    /// A tap offers a link, or clicks in a mouse-using program.
    func tap(at cell: (x: Int, y: Int)) -> TapResult {
        guard let vt else { return .unhandled }
        if let url = vt.link(at: cell, in: frame) { return .link(url) }
        if let click = vt.click(column: cell.x, row: cell.y) {
            send(click)
            return .handled
        }
        return .unhandled
    }

    // MARK: Rendering

    /// The shortest wait between rendered frames: quick while the terminal is on screen, slower
    /// while the chat covers it (nobody sees the frames then; the chat only needs them now and then).
    static func minInterval(drawing: Bool) -> Duration {
        drawing ? .milliseconds(8) : .milliseconds(100)
    }

    /// Whether the terminal canvas is on screen (not covered by the chat). Showing it again
    /// renders the pending frame at once.
    var drawing = true {
        didSet {
            guard drawing, !oldValue, renderTask != nil else { return }
            renderTask?.cancel()
            renderTask = nil
            renderNow()
        }
    }

    /// Coalesces bursts of output into one frame.
    private func scheduleRender() {
        guard renderTask == nil else { return }
        let interval = Self.minInterval(drawing: drawing)
        renderTask = Task { @MainActor in
            do { try await Task.sleep(for: interval) } catch { return }
            renderTask = nil
            renderNow()
        }
    }

    private func renderNow() {
        guard let vt else { return }
        frame = vt.frame()
        latency.rendered()
        reportStats()
        let lines = frame.textLines
        if let shown = predictor.shown {
            // By cell, not by character: a wide character (emoji, CJK) takes two cells.
            var rows = [String](repeating: "", count: frame.lines.count)
            if frame.lines.indices.contains(shown.row) { rows[shown.row] = Self.cellText(frame.lines[shown.row]) }
            predictor.frameChanged(lines: rows, cursor: frame.cursor.map { ($0.x, $0.y) },
                                   alternateScreen: vt.isAlternateScreen, now: .now)
            showPrediction()
        }
        guard lines != textLines else { return }
        textLines = lines
        let login = AnswerParser.inLogin(lines)
        if login != inLogin { inLogin = login }
    }

    #if DEBUG
    /// A screen's text without a terminal behind it, for tests: what a new frame sets.
    func showText(_ lines: [String]) {
        if lines != textLines { textLines = lines }
        let login = AnswerParser.inLogin(lines)
        if login != inLogin { inLogin = login }
    }
    #endif
}
