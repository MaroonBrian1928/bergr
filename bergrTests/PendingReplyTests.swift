import Testing
@testable import bergr

struct PendingReplyTests {
    @Test func queuedReplyUnderThePromptCounts() {
        let screen = ["⏺ Working…", "", "> I am signed in", "  ctrl+enter to send now"]
        #expect(ReplyPayload.onScreen("I am signed in", lines: screen))
    }

    @Test func longReplyMatchesOnItsStart() {
        let text = "It showed up as not sent, retry? but then once it actually sent it came back"
        #expect(ReplyPayload.onScreen(text, lines: ["> It showed up as not sent, retry? but th", "en once"]))
    }

    @Test func absentOrEmptyIsNotOnScreen() {
        #expect(!ReplyPayload.onScreen("I am signed in", lines: ["> ", "idle"]))
        #expect(!ReplyPayload.onScreen("  \n", lines: ["anything"]))
    }
}

struct PendingMatchTests {
    @Test func doubledMessageStillClearsTheBubble() {
        let text = "Is it because we don't have the project set"
        let reply = ReplyPayload(text: text, hasImages: false)
        #expect(reply.isIn([text + "\n" + text]))
    }

    @Test func shortRepliesNeedAnExactMatch() {
        #expect(!ReplyPayload(text: "yes", hasImages: false).isIn(["yes please do the other thing"]))
    }
}

struct PendingArrivalTests {
    private func user(_ id: String, _ text: String) -> ChatFeed.Item { .init(id: id, kind: .user(text)) }

    @Test func anEarlierSameMessageDoesntConfirm() {
        var reply = ReplyPayload(text: "yes", hasImages: false)
        reply.known = ["u1"]
        #expect(!reply.arrived(in: [user("u1", "yes")]))
        #expect(reply.arrived(in: [user("u1", "yes"), user("u2", "yes")]))
    }
}
