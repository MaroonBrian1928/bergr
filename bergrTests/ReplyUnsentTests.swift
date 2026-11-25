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

    @Test func enteredQueuedReplyStaysOutOfTheDraft() async {
        let rig = rig()
        rig.state = "working"
        rig.terminal.frameLines = ["  queued behind the step"]  // the agent shows it in its queue
        let reply = rig.send("queued behind the step")
        await rig.until { reply.entered }
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "")
        #expect(!ReplyDrafts.hasUnsent(for: "m|a", in: d))
    }

    @Test func returnPressedButNeverShownIsRestored() async {
        let rig = rig()
        rig.state = "working"
        let reply = rig.send("lost on the way")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!reply.entered)
        rig.outbox.cancelAll()
        #expect(ReplyDrafts.text(for: "m|a", in: d) == "lost on the way")
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

    @Test func submittedCodexRepliesSurviveReopeningWithoutAnotherEnter() async {
        let rig = ReplyRig(agent: .codex)
        rig.terminal.frameLines = ["queued behind the step"]
        rig.state = "working"
        let message = rig.send("queued behind the step")
        let command = rig.send("!ls")
        await rig.until { message.entered && command.entered }
        let pending = rig.outbox.cancelAll(keepingSubmitted: true, items: [])
        let reopened = ReplyOutbox()
        reopened.restorePending(pending, items: [])
        #expect(reopened.shown(in: [], search: nil).map(\.text) == ["queued behind the step", "!ls"])
        #expect(rig.terminal.count("enter") == 2)
        reopened.feedChanged([rig.user("u1", message.text), rig.user("u2", command.text)])
        #expect(reopened.replies.isEmpty)
    }

    @Test func reopeningSkipsRepliesAlreadyRecordedWhileAway() async {
        let rig = ReplyRig(agent: .codex)
        let reply = rig.send("!ls")
        await rig.until { reply.entered }
        let pending = rig.outbox.cancelAll(keepingSubmitted: true, items: [])
        let reopened = ReplyOutbox()
        reopened.restorePending(pending, items: [rig.user("u1", "!ls")])
        #expect(reopened.replies.isEmpty)
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
