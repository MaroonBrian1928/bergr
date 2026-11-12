import CoreGraphics
import Testing
@testable import bergr

struct ChatListModelTests {
    private func e(_ id: String, _ v: Int = 0) -> ChatListDiff.Entry { .init(id: id, version: v) }

    @Test func streamedTokenChangesOneRow() {
        let c = ChatListDiff.changes(from: [e("a"), e("b"), e("c")], to: [e("a"), e("b"), e("c", 1)])
        #expect(c == .init(changed: [2]))
    }

    @Test func appendPrependAndRemove() {
        let c = ChatListDiff.changes(from: [e("a"), e("b"), e("c")], to: [e("x"), e("y"), e("a"), e("c"), e("d")])
        #expect(c.removed == [1])
        #expect(c.inserted == [0, 1, 4])
        #expect(c.changed.isEmpty)
        #expect(!c.reordered)
    }

    @Test func reorderNeedsReload() {
        #expect(ChatListDiff.changes(from: [e("a"), e("b")], to: [e("b"), e("a")]).reordered)
        #expect(ChatListDiff.changes(from: [e("a")], to: [e("a")]).isEmpty)
    }

    @Test func heightCacheInvalidatesOnVersionAndWidth() {
        var cache = RowHeightCache()
        let first = cache.set(40, id: "a", version: 1, width: 800)
        #expect(first)
        #expect(cache.height(id: "a", version: 1, width: 800) == 40)
        #expect(cache.height(id: "a", version: 2, width: 800) == nil)
        #expect(cache.height(id: "a", version: 1, width: 600) == nil)
        let again = cache.set(40, id: "a", version: 1, width: 800)
        #expect(!again)
        cache.keep(["b"])
        #expect(cache.count == 0)
    }

    @Test func followDecisions() {
        #expect(ChatFollow.follows(distance: 48))
        #expect(!ChatFollow.follows(distance: 49))
        #expect(ChatFollow.distanceToBottom(contentHeight: 1000, bottomInset: 10, visibleMaxY: 1010) == 0)
        // Following: to the bottom.
        #expect(ChatFollow.origin(following: true, current: 100, anchor: nil, minOrigin: -12, bottom: 500) == 500)
        // Earlier rows landed above the anchor (it moved down 300): the view moves with it.
        #expect(ChatFollow.origin(following: false, current: 0, anchor: (0, 300), minOrigin: -12, bottom: 900) == 300)
        // Short content sits at the bottom.
        #expect(ChatFollow.topInset(base: 12, bottomInset: 10, contentHeight: 100, viewport: 500) == 390)
        #expect(ChatFollow.bottomOrigin(contentHeight: 100, topInset: 390, bottomInset: 10, viewport: 500) == -390)
    }
}
