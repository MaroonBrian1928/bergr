import Foundation
import Testing
@testable import bergr

@MainActor struct ReplyUnsentTests {
    private let d = UserDefaults(suiteName: "ReplyUnsentTests-\(UUID().uuidString)")!

    private func rig() -> ReplyRig {
        let rig = ReplyRig()
        rig.outbox.draftKey = "m|a"
        rig.outbox.defaults = d
        return rig
    }

    @Test func cancelRestoresQueuedInOrder() {
        let rig = rig()
        rig.state = "working"
        _ = rig.send("first")
        _ = rig.send("second")
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "first\n\nsecond")
        #expect(ReplyDrafts.hasUnsent(for: "m|a", in: d))
        #expect(rig.outbox.replies.isEmpty)
    }

    @Test func failedIsRestored() async {
        let rig = rig()
        let reply = rig.send("lost one")
        await rig.until { reply.phase == .failed }
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "lost one")
    }

    @Test func deliveredIsNotRestored() {
        let rig = rig()
        rig.state = "working"
        _ = rig.send("seen")
        _ = rig.send("unseen")
        rig.items = [rig.user("u1", "seen")]
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "unseen")
    }

    @Test func appendsToExistingDraftAndDoesNotDuplicate() {
        let rig = rig()
        ReplyDrafts.set("half typed", for: "m|a", in: d)
        rig.state = "working"
        _ = rig.send("queued")
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "half typed\n\nqueued")
        _ = rig.send("queued")
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "half typed\n\nqueued")
    }

    @Test func indicatorEndsWhenDraftIsEditedOrSent() {
        ReplyDrafts.restore(["x"], for: "m|a", in: d)
        #expect(ReplyDrafts.hasUnsent(for: "m|a", in: d))
        ReplyDrafts.set("x edited", for: "m|a", in: d)
        #expect(!ReplyDrafts.hasUnsent(for: "m|a", in: d))
        ReplyDrafts.restore(["y"], for: "m|b", in: d)
        ReplyDrafts.set("", for: "m|b", in: d)
        #expect(!ReplyDrafts.hasUnsent(for: "m|b", in: d))
    }

    @Test func imageOnlyReplyAddsNoText() {
        let rig = rig()
        rig.state = "working"
        _ = rig.send("", images: [rig.image()])
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "")
    }
}
