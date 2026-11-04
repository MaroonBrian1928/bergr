import Foundation
import UIKit
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
    /// Soft-keyboard Ctrl: applies to the next key.
    var controlLatched = false
    /// Scrolled up into history (new output does not move the view).
    private(set) var scrolledBack = false
    /// Whether the software keyboard should be up; the canvas keeps it in sync.
    var wantsKeyboard = false

    private var vt: VirtualTerminal?
    private var attached: AttachedTerminal?
    private var pump: Task<Void, Never>?
    private var renderScheduled = false
    /// What this view would like (fits its bounds); sent whenever we act.
    private var preferredSize: (cols: Int, rows: Int)?

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

    /// Starts once the view knows how many cells fit.
    func start(session: HostSession, address: String, cols: Int, rows: Int) {
        preferredSize = (cols, rows)
        guard pump == nil else { return }
        phase = .attaching
        pump = Task { await run(session: session, address: address, cols: cols, rows: rows) }
    }

    func stop() {
        pump?.cancel()
        pump = nil
        let attached = self.attached
        self.attached = nil
        Task { await attached?.detach() }
    }

    private func run(session: HostSession, address: String, cols: Int, rows: Int) async {
        do {
            // Attaching makes us the active viewer: the core resizes the terminal to our size.
            let attached = try await session.attach(
                address: address, cols: cols, rows: rows, display: theme.displayFacts)
            self.attached = attached
            let vt = try VirtualTerminal(
                cols: max(attached.terminal.cols, 1), rows: max(attached.terminal.rows, 1))
            Self.apply(theme, to: vt)
            self.vt = vt
            phase = .live
            for try await chunk in attached.output {
                vt.write(chunk)
                scheduleRender()
            }
            if !Task.isCancelled { phase = .ended("Detached.") }
        } catch is CancellationError {
        } catch let end as StreamEnd {
            phase = .ended(end.localizedDescription)
        } catch {
            if !Task.isCancelled { phase = .failed(error.localizedDescription) }
        }
        renderNow()
    }

    // MARK: Size

    /// The terminal's real size changed (another viewer took over, or our resize applied).
    func remoteSizeChanged(cols: Int, rows: Int) {
        guard let vt, cols > 0, rows > 0, cols != vt.cols || rows != vt.rows else { return }
        vt.resize(cols: cols, rows: rows)
        renderNow()
    }

    /// The view's grid changed (rotation, fold, font size).
    func viewSizeChanged(cols: Int, rows: Int) {
        guard preferredSize.map({ $0.cols != cols || $0.rows != rows }) ?? true else { return }
        preferredSize = (cols, rows)
        claimSize()
    }

    /// Makes our size the terminal's size: resizing counts as activity.
    private func claimSize() {
        guard let attached, let size = preferredSize else { return }
        vt?.resize(cols: size.cols, rows: size.rows)
        renderNow()
        Task { try? await attached.resize(cols: size.cols, rows: size.rows) }
    }

    /// Whether another viewer currently sets a different size than ours.
    var sizeOwnedElsewhere: Bool {
        guard let vt, let size = preferredSize else { return false }
        return vt.cols != size.cols || vt.rows != size.rows
    }

    // MARK: Input

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
        guard let attached else { return }
        if focused && sizeOwnedElsewhere { claimSize() }
        Task { try? await attached.focus(focused) }
    }

    private func send(_ data: Data) {
        guard let attached, !data.isEmpty else { return }
        // Typing makes us the active viewer again; show the live screen.
        if scrolledBack { scroll(toBottom: true) }
        if sizeOwnedElsewhere { claimSize() }
        Task { try? await attached.send(data) }
    }

    // MARK: Scrolling

    /// A scroll gesture over a cell: to the program (mouse wheel / arrows) or our history.
    func scroll(lines: Int, column: Int, row: Int) {
        guard let vt, lines != 0 else { return }
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

    /// A tap clears a selection, offers a link, or clicks in a mouse-using program.
    func tap(at cell: (x: Int, y: Int)) -> TapResult {
        guard let vt else { return .unhandled }
        if hasSelection {
            clearSelection()
            return .handled
        }
        if let url = vt.link(at: cell, in: frame) { return .link(url) }
        if let click = vt.click(column: cell.x, row: cell.y) {
            send(click)
            return .handled
        }
        return .unhandled
    }

    // MARK: Selection

    var hasSelection: Bool { frame.selection.contains { $0 != nil } }

    func selectWord(at cell: (x: Int, y: Int)) {
        vt?.selectWord(at: cell)
        renderNow()
    }

    func select(from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        vt?.select(from: start, to: end)
        renderNow()
    }

    func clearSelection() {
        guard hasSelection else { return }
        vt?.clearSelection()
        renderNow()
    }

    /// Copies the selection to the clipboard; returns whether there was anything to copy.
    @discardableResult
    func copySelection() -> Bool {
        guard let text = vt?.selectedText(), !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        return true
    }

    // MARK: Rendering

    /// Coalesces bursts of output into one frame.
    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(8))
            renderScheduled = false
            renderNow()
        }
    }

    private func renderNow() {
        guard let vt else { return }
        frame = vt.frame()
    }
}
