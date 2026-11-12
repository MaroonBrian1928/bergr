import CoreGraphics

/// The decisions behind the Mac's chat table (`bergrMac/Chat/ChatTable.swift`), kept free of
/// AppKit so they can be tested: which rows changed, which heights are still good, and where the
/// list stands after a change.
enum ChatListDiff {
    /// A row as the table knows it: its id and a count of its content's changes.
    struct Entry: Equatable {
        let id: String
        let version: Int
    }

    struct Changes: Equatable {
        /// Indexes in the old list.
        var removed: [Int] = []
        /// Indexes in the new list.
        var inserted: [Int] = []
        /// Indexes in the new list of rows kept whose content changed.
        var changed: [Int] = []
        /// The kept rows changed order: only a full reload brings the table up to date.
        var reordered = false

        var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && changed.isEmpty && !reordered }
    }

    static func changes(from old: [Entry], to new: [Entry]) -> Changes {
        var changes = Changes()
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (i, entry) in old.enumerated() { oldIndex[entry.id] = i }
        let newIDs = Set(new.map(\.id))
        for (i, entry) in old.enumerated() where !newIDs.contains(entry.id) { changes.removed.append(i) }
        var lastKept = -1
        for (i, entry) in new.enumerated() {
            guard let at = oldIndex[entry.id] else {
                changes.inserted.append(i)
                continue
            }
            if at < lastKept { changes.reordered = true }
            lastKept = at
            if old[at].version != entry.version { changes.changed.append(i) }
        }
        return changes
    }
}

/// Row heights, good for one version of a row's content at one width.
struct RowHeightCache {
    private var heights: [String: (version: Int, width: CGFloat, height: CGFloat)] = [:]

    func height(id: String, version: Int, width: CGFloat) -> CGFloat? {
        guard let entry = heights[id], entry.version == version, entry.width == width else { return nil }
        return entry.height
    }

    /// Stores a measurement; whether it differs from what was known for that version and width.
    @discardableResult
    mutating func set(_ height: CGFloat, id: String, version: Int, width: CGFloat) -> Bool {
        let old = self.height(id: id, version: version, width: width)
        heights[id] = (version, width, height)
        return old.map { abs($0 - height) > 0.5 } ?? true
    }

    /// The last height measured for a row, whatever its version or width.
    func latest(id: String) -> CGFloat? { heights[id]?.height }

    /// Forgets the rows that left the list.
    mutating func keep(_ ids: Set<String>) {
        heights = heights.filter { ids.contains($0.key) }
    }

    var count: Int { heights.count }
}

/// Bottom-anchored scrolling: the list follows new content while the reader is at the end.
enum ChatFollow {
    /// Within this of the bottom, the list follows what arrives.
    static let threshold: CGFloat = 48

    /// From the bottom of what is visible to the end of the content (with its bottom inset).
    static func distanceToBottom(contentHeight: CGFloat, bottomInset: CGFloat, visibleMaxY: CGFloat) -> CGFloat {
        contentHeight + bottomInset - visibleMaxY
    }

    static func follows(distance: CGFloat) -> Bool { distance <= threshold }

    /// The scroll origin (top of the visible area) at the bottom of the content.
    static func bottomOrigin(contentHeight: CGFloat, topInset: CGFloat, bottomInset: CGFloat, viewport: CGFloat) -> CGFloat {
        max(-topInset, contentHeight + bottomInset - viewport)
    }

    /// The top inset that keeps content shorter than the viewport at its bottom.
    static func topInset(base: CGFloat, bottomInset: CGFloat, contentHeight: CGFloat, viewport: CGFloat) -> CGFloat {
        max(base, viewport - contentHeight - bottomInset)
    }

    /// Where the visible area goes after the content changed: at the bottom while following,
    /// else so the row that was at the top (`anchor`, its top before and after) stays put.
    static func origin(following: Bool, current: CGFloat, anchor: (before: CGFloat, after: CGFloat)?,
                       minOrigin: CGFloat, bottom: CGFloat) -> CGFloat {
        if following { return bottom }
        let moved = anchor.map { $0.after - $0.before } ?? 0
        return min(max(current + moved, minOrigin), max(bottom, minOrigin))
    }
}
