import HerdrKit
import SwiftUI

/// A live look at a terminal for a row's long-press menu: watched (herdr-core's `observe`), so
/// it neither resizes the terminal nor takes it over, and detached once the menu closes.
/// Readable rather than whole: a desktop terminal shrunk to a phone's width can't be read, so
/// this shows its last lines (up to the cursor) at a small but readable size, cut off on the
/// right. Watching it (from the menu) shows all of it.
struct TerminalPeek: View {
    let session: HostSession
    let terminal: Terminal
    /// As wide as the preview may be (the row's width); 0 for the screen's.
    var maxWidth: CGFloat = 0
    @State private var model: TerminalScreenModel
    /// The canvas's grid, once reported: SwiftUI keeps this view's state from one long-press to
    /// the next, and an unchanged grid isn't reported again, so appearing starts from it.
    @State private var grid: (cols: Int, rows: Int)?
    @AppStorage(TerminalFont.storageKey) private var fontFamily = TerminalFont.jetBrainsMono
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var colorScheme

    private var theme: TerminalTheme { TerminalTheme.current(colorScheme, light: lightTheme, dark: darkTheme) }

    init(session: HostSession, terminal: Terminal, maxWidth: CGFloat = 0) {
        self.session = session
        self.terminal = terminal
        self.maxWidth = maxWidth
        let defaults = UserDefaults.standard
        let style = UITraitCollection.current.userInterfaceStyle
        _model = State(initialValue: TerminalScreenModel(theme: TerminalTheme.current(
            style == .dark ? .dark : .light,
            light: defaults.string(forKey: TerminalTheme.lightKey) ?? TerminalTheme.defaultLight,
            dark: defaults.string(forKey: TerminalTheme.darkKey) ?? TerminalTheme.defaultDark)))
    }

    var body: some View {
        ZStack {
            Color(uiColor: UIColor(model.frame.cols == 0 ? theme.backgroundRGB : model.frame.background))
            TerminalCanvas(
                model: model, fontSize: .constant(Self.fontSize), fontFamily: fontFamily, dark: theme.dark, cropped: true
            ) { cols, rows in
                grid = (cols, rows)
                if case .attaching = model.phase { start() }
            }
            .allowsHitTesting(false)
            if case .attaching = model.phase {
                ProgressView().tint(theme.dark ? .white : .black)
            }
        }
        .frame(width: size.width, height: size.height)
        .onChange(of: theme, initial: true) { _, theme in model.theme = theme }
        .onChange(of: session.terminal(terminal.address).map { [$0.cols, $0.rows] }) { _, size in
            if let size { model.remoteSizeChanged(cols: size[0], rows: size[1]) }
        }
        .onAppear {
            // Again after an earlier long-press (it stopped when that menu closed).
            if grid != nil { start() }
        }
        // A peek leaves an unread agent unread (herdr-app's labels.md counts peeks as looking;
        // here a glance isn't reading it). Opening it reads it.
        .onDisappear { model.stop() }
    }

    /// Watches the terminal; does nothing while already watching it.
    private func start() {
        guard let grid else { return }
        model.start(session: session, address: terminal.address, cols: grid.cols, rows: grid.rows, watch: true)
    }

    /// Small, but readable.
    private static let fontSize = 10.0
    /// Lines shown at most: enough for what an agent is doing or asking.
    private static let maxLines = 18

    /// As wide as the row (no wider than the terminal), as tall as its lines up to `maxLines`.
    private var size: CGSize {
        let cell = Fonts(size: Self.fontSize, family: fontFamily)
        let margin = 2 * TerminalCanvasView.padding
        let available = min(maxWidth > 0 ? maxWidth : UIScreen.main.bounds.width - 32, 600)
        let width = min(available, CGFloat(max(terminal.cols, 1)) * cell.cellWidth + margin)
        let lines = CGFloat(min(max(terminal.rows, 1), Self.maxLines))
        return CGSize(width: width, height: lines * cell.cellHeight + margin)
    }
}
