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
        if pump != nil, attached == nil { return }
        if let at = attachedAt, Date.now.timeIntervalSince(at) < 3 { return }
        stop()
        pump = Task { await run() }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        let attached = self.attached
        self.attached = nil
        Task { await attached?.detach() }
    }

    /// Switches between watching and being a viewer. A channel can't change its kind, so this
    /// attaches again; the old screen stays up until the new one's first paint.
    func setWatching(_ watch: Bool) {
        guard watch != watching else { return }
        watching = watch
        // Watching means not typing: put the keyboard away (bringing it back takes over).
        if watch { wantsKeyboard = false }
        guard pump != nil, phase == .live else { return }
        stop()
        pump = Task { await run() }
    }

    /// Lines of earlier output to ask for when attaching, so there is something to scroll back to.
    static let historyLines = 1000

    private func run() async {
        guard let session, let address, let size = preferredSize else { return }
        let observe = watching
        do {
            // Attaching as a viewer makes us the active one: the core resizes the terminal to our
            // size. An observer leaves it at the size the active viewer (or nobody) set.
            let attached = try await session.attach(
                address: address, cols: size.cols, rows: size.rows, history: Self.historyLines, observe: observe,
                display: theme.displayFacts)
            guard !Task.isCancelled else { return await attached.detach() }
            self.attached = attached
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
                for data in pendingInput { try? await attached.send(data) }
            }
            pendingInput.removeAll()
            for try await chunk in attached.output {
                vt.write(chunk)
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
    func automate(_ steps: @escaping @MainActor () async -> Void) async {
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
            controlLatched = false
            press(c == " " ? .space : .letter(c), modifiers: .control, text: nil)
            return
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
        send(vt.encode(key, modifiers: modifiers, text: text))
    }

    func paste(_ text: String) {
        guard let vt, !text.isEmpty else { return }
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

    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
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
        Task {
            if focusFirst { try? await attached.focus(true) }
            try? await attached.send(data)
        }
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
        let lines = frame.textLines
        if lines != textLines { textLines = lines }
        let login = AnswerParser.inLogin(lines)
        if login != inLogin { inLogin = login }
    }
}
