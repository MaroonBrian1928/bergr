import Testing
@testable import bergr

struct PendingReplyTests {
    @Test func queuedReplyUnderThePromptCounts() {
        let screen = ["⏺ Working…", "", "> I am signed in", "  ctrl+enter to send now"]
        #expect(ChatView.Pending.onScreen("I am signed in", lines: screen))
    }

    @Test func longReplyMatchesOnItsStart() {
        let text = "It showed up as not sent, retry? but then once it actually sent it came back"
        #expect(ChatView.Pending.onScreen(text, lines: ["> It showed up as not sent, retry? but th", "en once"]))
    }

    @Test func absentOrEmptyIsNotOnScreen() {
        #expect(!ChatView.Pending.onScreen("I am signed in", lines: ["> ", "idle"]))
        #expect(!ChatView.Pending.onScreen("  \n", lines: ["anything"]))
    }
}
