import AppKit
import SwiftUI

/// One row of the Mac chat table: its content is built only when `version` changes.
struct ChatTableItem {
    let id: String
    let version: Int
    let make: () -> AnyView
}

/// What the chat asks of its table from outside it (the jump-to-latest button, sending).
@MainActor final class ChatScrollControl {
    fileprivate weak var table: ChatTable.Coordinator?
    func scrollToBottom(animated: Bool) { table?.scrollToBottom(animated: animated) }
}

/// The chat's scroll view on the Mac (found by `MacStress`).
final class ChatTableScrollView: NSScrollView {
    var onWindow: (() -> Void)?
    /// The table's coordinator, for the debug checks in `MacStress`.
    weak var table: ChatTable.Coordinator?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?()
    }
}

/// The conversation on the Mac: a view-based `NSTableView`, each row the chat's SwiftUI row in
/// its own hosting view. Scrolling moves the rows' layers; a streamed token rebuilds and remeasures
/// only the row it changed. Bottom-anchored: it opens at the end and follows what arrives while
/// the reader is within `ChatFollow.threshold` of it; otherwise what they look at stays still.
struct ChatTable: NSViewRepresentable {
    let items: [ChatTableItem]
    /// The safe area the table scrolls under (toolbar, header, the floating reply bar).
    let insets: EdgeInsets
    let control: ChatScrollControl
    let onDistance: (BottomDistance) -> Void

    /// Room above the first row and below the last (the row spacing is part of each row).
    static let topPadding: CGFloat = 12
    static let bottomPadding: CGFloat = 28
    static let spacing: CGFloat = 18

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    /// Whatever it is offered: its size never depends on its rows (asking AppKit for the scroll
    /// view's fitting size made the window's layout depend on the table's).
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let c = context.coordinator
        control.table = c
        c.onDistance = onDistance
        c.environment = context.environment
        c.update(items: items, safeTop: insets.top, safeBottom: insets.bottom)
    }

    /// A row's hosting view, with the row spacing below it. Ignores the pointer while scrolling.
    final class Cell: NSView {
        let host: NSHostingController<CellRoot>
        weak var owner: Coordinator?
        override var isFlipped: Bool { true }

        init(root: CellRoot) {
            host = NSHostingController(rootView: root)
            host.sizingOptions = []
            super.init(frame: .zero)
            wantsLayer = true
            addSubview(host.view)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            host.view.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - ChatTable.spacing))
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            owner?.scrolling == true ? nil : super.hitTest(point)
        }
    }

    struct CellRoot: View {
        let content: AnyView
        let environment: EnvironmentValues
        let onHeight: (CGFloat) -> Void

        var body: some View {
            content
                .padding(.horizontal, 16)
                // A readable line length on a wide window, centered.
                .frame(maxWidth: ChatView.readableWidth)
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                // Grows by itself (a tool run opened, an image arrived, text revealing): the
                // table learns the row's new height.
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight($0) }
                .environment(\.self, environment)
        }
    }

    final class Table: NSTableView {
        /// The rows' heights added up, from the coordinator's cache (asking the table for its
        /// rows' rects here makes it measure inside its own update).
        var rowsHeight: CGFloat = 0
        /// As tall as its rows, not the visible area: the bottom anchoring measures from it.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(NSSize(width: newSize.width, height: rowsHeight))
        }
        override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let scrollView = ChatTableScrollView()
        let table = Table()
        var onDistance: (BottomDistance) -> Void = { _ in }
        var environment = EnvironmentValues()
        private(set) var scrolling = false

        private var items: [ChatTableItem] = []
        private var entries: [ChatListDiff.Entry] = []
        private var cells: [String: Cell] = [:]
        private var heights = RowHeightCache()
        private var following = true
        /// Moving the list ourselves: the reader's position isn't read from it meanwhile.
        private var adjusting = 0
        private var jumping = false
        private var reported: BottomDistance?
        private var safeTop: CGFloat = 0
        private var safeBottom: CGFloat = 0
        private var width: CGFloat = 0
        private var pendingHeights: Set<String> = []

        override init() {
            super.init()
            let column = NSTableColumn(identifier: .init("row"))
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.headerView = nil
            table.style = .plain
            table.backgroundColor = .clear
            table.intercellSpacing = .zero
            table.selectionHighlightStyle = .none
            table.gridStyleMask = []
            table.usesAutomaticRowHeights = false
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.focusRingType = .none
            table.allowsColumnResizing = false
            table.allowsColumnReordering = false
            table.dataSource = self
            table.delegate = self
            table.wantsLayer = true
            table.layerContentsRedrawPolicy = .never

            scrollView.documentView = table
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.drawsBackground = false
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.wantsLayer = true
            scrollView.contentView.wantsLayer = true
            scrollView.contentView.drawsBackground = false
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.postsFrameChangedNotifications = true

            scrollView.table = self
            scrollView.onWindow = { [weak self] in self?.frameChanged() }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            center.addObserver(self, selector: #selector(frameChanged), name: NSView.frameDidChangeNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            center.addObserver(self, selector: #selector(liveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        }

        // MARK: Updates

        func update(items new: [ChatTableItem], safeTop: CGFloat, safeBottom: CGFloat) {
            let insetsChanged = safeTop != self.safeTop || safeBottom != self.safeBottom
            self.safeTop = safeTop
            self.safeBottom = safeBottom
            let next = new.map { ChatListDiff.Entry(id: $0.id, version: $0.version) }
            let changes = ChatListDiff.changes(from: entries, to: next)
            items = new
            guard !changes.isEmpty || insetsChanged else { return }
            if width == 0 { width = scrollView.contentView.bounds.width }
            preserve {
                let old = entries
                entries = next
                if changes.reordered || old.isEmpty {
                    let ids = Set(next.map(\.id))
                    for id in cells.keys where !ids.contains(id) { cells[id] = nil }
                    for i in changes.changed { refresh(i) }
                    // Measured before the table asks: it only reads the cache.
                    for i in items.indices { measureIfNeeded(i) }
                    table.reloadData()
                } else {
                    table.beginUpdates()
                    if !changes.removed.isEmpty {
                        table.removeRows(at: IndexSet(changes.removed), withAnimation: [])
                        for i in changes.removed { cells[old[i].id] = nil }
                    }
                    for i in changes.inserted { measureIfNeeded(i) }
                    if !changes.inserted.isEmpty { table.insertRows(at: IndexSet(changes.inserted), withAnimation: []) }
                    table.endUpdates()
                    var resized = IndexSet()
                    for i in changes.changed where refresh(i) { resized.insert(i) }
                    if !resized.isEmpty { table.noteHeightOfRows(withIndexesChanged: resized) }
                }
                heights.keep(Set(next.map(\.id)))
            }
        }

        /// Builds a changed row again and measures it; whether its height changed.
        @discardableResult
        private func refresh(_ index: Int) -> Bool {
            let item = items[index]
            guard let cell = cells[item.id] else { return true }
            cell.host.rootView = root(item)
            return heights.set(measure(cell), id: item.id, version: item.version, width: width)
        }

        private func measureIfNeeded(_ index: Int) {
            let item = items[index]
            guard heights.height(id: item.id, version: item.version, width: width) == nil else { return }
            heights.set(measure(cell(at: index)), id: item.id, version: item.version, width: width)
        }

        private func root(_ item: ChatTableItem) -> CellRoot {
            let id = item.id
            return CellRoot(content: item.make(), environment: environment) { [weak self] height in
                self?.heightReported(id: id, content: height)
            }
        }

        private func cell(at index: Int) -> Cell {
            let item = items[index]
            if let cell = cells[item.id] { return cell }
            let cell = Cell(root: root(item))
            cell.owner = self
            cells[item.id] = cell
            return cell
        }

        private func measure(_ cell: Cell) -> CGFloat {
            if cell.frame.width != width {
                cell.frame.size.width = width
                cell.host.view.frame.size.width = width
            }
            let size = cell.host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            return (size.height.isFinite && size.height < 1e6 ? ceil(size.height) : 0) + ChatTable.spacing
        }

        /// A row's content settled at a new height by itself (see `CellRoot`).
        private func heightReported(id: String, content: CGFloat) {
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            let entry = entries[index]
            let height = ceil(content) + ChatTable.spacing
            guard let known = heights.height(id: id, version: entry.version, width: width),
                  abs(known - height) > 0.5 else { return }
            heights.set(height, id: id, version: entry.version, width: width)
            // Not inside SwiftUI's layout pass that reported it.
            let first = pendingHeights.isEmpty
            pendingHeights.insert(id)
            guard first else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let ids = pendingHeights
                pendingHeights = []
                let rows = IndexSet(entries.indices.filter { ids.contains(self.entries[$0].id) })
                guard !rows.isEmpty else { return }
                preserve { self.table.noteHeightOfRows(withIndexesChanged: rows) }
            }
        }

        // MARK: Position

        private var contentHeight: CGFloat { table.rowsHeight }
        private var cachedTotal: CGFloat {
            items.reduce(0) { sum, item in
                sum + (heights.height(id: item.id, version: item.version, width: width) ?? heights.latest(id: item.id) ?? ChatTable.spacing)
            }
        }
        private var bottomInset: CGFloat { safeBottom + ChatTable.bottomPadding - ChatTable.spacing }
        /// The window's toolbar over the table (it reaches under it), from AppKit.
        private var toolbarInset: CGFloat {
            guard let window = scrollView.window else { return 0 }
            let top = scrollView.convert(scrollView.bounds, to: nil).maxY
            return max(0, (top - window.contentLayoutRect.maxY).rounded())
        }
        private var viewport: CGFloat { scrollView.contentView.bounds.height }

        private func applyInsets() {
            let top = ChatFollow.topInset(base: toolbarInset + safeTop + ChatTable.topPadding, bottomInset: bottomInset,
                                          contentHeight: contentHeight, viewport: viewport)
            let insets = NSEdgeInsets(top: top, left: 0, bottom: bottomInset, right: 0)
            let old = scrollView.contentInsets
            if old.top != insets.top || old.bottom != insets.bottom {
                scrollView.contentInsets = insets
                scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            }
        }

        private var bottomOrigin: CGFloat {
            ChatFollow.bottomOrigin(contentHeight: contentHeight, topInset: scrollView.contentInsets.top,
                                    bottomInset: bottomInset, viewport: viewport)
        }

        /// Makes a change to the rows: afterwards the list is at the bottom if it followed, or the
        /// row at the top of the view is where it was (earlier rows landing above it, rows above
        /// it growing).
        private func preserve(_ change: () -> Void) {
            let clip = scrollView.contentView
            let origin = clip.bounds.minY
            var anchor: (id: String, top: CGFloat)?
            if !following, table.numberOfRows > 0 {
                // The first visible row of the conversation ("Earlier messages" stays on top as
                // earlier rows land under it).
                let visible = table.rows(in: clip.bounds)
                let rows = visible.location..<min(visible.location + visible.length, entries.count)
                if let row = rows.first(where: { !entries[$0].id.hasPrefix("chat.") }) ?? rows.first {
                    anchor = (entries[row].id, table.rect(ofRow: row).minY)
                }
            }
            adjusting += 1
            change()
            table.rowsHeight = cachedTotal
            table.tile()
            table.setFrameSize(NSSize(width: clip.bounds.width, height: contentHeight))
            applyInsets()
            var moved: (before: CGFloat, after: CGFloat)?
            if let anchor, let index = entries.firstIndex(where: { $0.id == anchor.id }) {
                moved = (anchor.top, table.rect(ofRow: index).minY)
            }
            let y = ChatFollow.origin(following: following, current: origin, anchor: moved,
                                      minOrigin: -scrollView.contentInsets.top, bottom: bottomOrigin)
            if abs(y - clip.bounds.minY) > 0.25 { scroll(to: y) }
            adjusting -= 1
            report()
        }

        private func scroll(to y: CGFloat) {
            let clip = scrollView.contentView
            clip.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(clip)
        }

        func scrollToBottom(animated: Bool) {
            following = true
            guard animated else {
                preserve {}
                return
            }
            jumping = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: bottomOrigin))
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.jumping = false
                    self.following = true
                    self.preserve {}
                }
            }
        }

        @objc private func boundsChanged() {
            guard adjusting == 0 else { return }
            if !jumping { following = ChatFollow.follows(distance: distance) }
            report()
        }

        @objc func frameChanged() {
            let newWidth = scrollView.contentView.bounds.width
            preserve {
                if newWidth != width {
                    width = newWidth
                    for item in items {
                        if let cell = cells[item.id] { heights.set(measure(cell), id: item.id, version: item.version, width: width) }
                    }
                    table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
                }
            }
        }

        @objc private func liveScroll(_ note: Notification) {
            scrolling = note.name == NSScrollView.willStartLiveScrollNotification
        }

        private var distance: CGFloat {
            ChatFollow.distanceToBottom(contentHeight: contentHeight, bottomInset: bottomInset,
                                        visibleMaxY: scrollView.contentView.bounds.maxY)
        }

        /// Tells the chat only when the bottom crosses one of its thresholds.
        private func report() {
            let now = BottomDistance(below: distance)
            guard now != reported else { return }
            reported = now
            let onDistance = onDistance
            DispatchQueue.main.async { onDistance(now) }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            // Only the cache: rows are measured before the table hears of them (measuring here
            // lays SwiftUI out inside the table's own update, which AppKit flags as reentrant).
            let item = items[row]
            if let height = heights.height(id: item.id, version: item.version, width: width) { return height }
            return heights.latest(id: item.id) ?? ChatTable.spacing
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            cell(at: row)
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        #if DEBUG
        /// Where the list stands, for `MacStress`'s checks.
        var debugState: String {
            let clip = scrollView.contentView.bounds
            let visible = table.rows(in: clip)
            var top = "-"
            if visible.length > 0, visible.location < entries.count {
                top = "\(entries[visible.location].id)@\(Int(table.rect(ofRow: visible.location).minY - clip.minY))"
            }
            return "following=\(following) distance=\(Int(distance)) rows=\(entries.count) top=\(top) width=\(Int(width)) content=\(Int(contentHeight)) insets=\(Int(scrollView.contentInsets.top))/\(Int(scrollView.contentInsets.bottom))"
        }

        func debugScroll(to y: CGFloat) { scroll(to: y); boundsChanged() }

        /// Clicks the middle of a row, as the pointer would.
        func debugClick(row: Int) {
            guard row < table.numberOfRows, let window = scrollView.window else { return }
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.minY + (rect.height - ChatTable.spacing) / 2), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
        }
        #endif
    }
}
