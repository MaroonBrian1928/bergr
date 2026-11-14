import Foundation
import Testing
@testable import bergr

@MainActor
struct AgentVoiceTests {
    private actor Fake: OnDeviceTextWriting {
        let answer: String?
        init(_ answer: String?) { self.answer = answer }
        func write(instructions: String, prompt: String, timeout: Duration) async -> String? { answer }
    }

    @Test func shortensToThreeSentences() {
        let message = "I fixed the bug. The tests pass now. I also renamed a file. Next I will update the docs."
        #expect(AgentVoice.firstSentences(message) == "I fixed the bug. The tests pass now. I also renamed a file.")
    }

    @Test func dropsCodeAndMarkdown() {
        let message = "## Done\nI changed **three** files:\n```swift\nlet x = 1\n```\n- see [the docs](http://x.y)\n- `ok`"
        #expect(AgentVoice.firstSentences(message) == "Done. I changed three files: see the docs. ok.")
    }

    @Test func readLatestFallsBackToTheCutWithoutAModel() async {
        let text = await AgentVoice.readLatest(agent: "Docs", message: "One. Two. Three. Four.", writer: Fake(nil))
        #expect(text == "Docs said: One. Two. Three.")
    }

    @Test func readLatestUsesTheSummaryWhenThereIsOne() async {
        let text = await AgentVoice.readLatest(
            agent: "Docs", message: "One. Two. Three. Four.", writer: Fake("It finished."))
        #expect(text == "Docs said: It finished.")
    }

    @Test func readLatestWithNothingSaid() async {
        let text = await AgentVoice.readLatest(agent: "Docs", message: nil, writer: Fake(nil))
        #expect(text == "Docs hasn't said anything yet.")
    }

    @Test func dialogStrings() {
        #expect(AgentVoice.sentDialog(.sent, agent: "Docs") == "Sent to Docs")
        #expect(AgentVoice.sentDialog(.waitingOnQuestion, agent: "Docs") == "Docs is waiting on a question — opened it")
    }

    @Test func sendDecisionFreeTextSendsBlockedSavesDraft() async throws {
        final class Log { var sent: [[PromptStep]] = []; var opened: [String] = [] }
        let defaults = try #require(UserDefaults(suiteName: "bergr.tests.voice.\(UUID().uuidString)"))
        let host = UUID()
        func flow(_ log: Log, lines: [String]) -> AnswerFlow {
            var f = AnswerFlow(
                screen: { _ in nil }, openChat: { log.opened.append($1) },
                replyScreen: { _ in
                    AnswerFlow.Screen(status: nil, lines: lines, send: { log.sent.append($0) },
                                      record: { _, _ in }, close: {})
                })
            f.draftDefaults = defaults
            return f
        }
        let free = Log()
        let a = await flow(free, lines: ["> "]).reply(ReplyNotificationRequest(host: host, address: "t1", text: "go"))
        #expect(a == .sent && IntentSendOutcome(a) == .sent)
        #expect(free.sent == [[.text("go"), .enter]] && free.opened.isEmpty)

        let blocked = Log()
        let menu = ["Do you want to proceed?", "❯ 1. Yes", "  2. No", ""]
        let b = await flow(blocked, lines: menu).reply(ReplyNotificationRequest(host: host, address: "t1", text: "go"))
        #expect(b == .savedAsDraft && IntentSendOutcome(b) == .waitingOnQuestion)
        #expect(blocked.sent.isEmpty && blocked.opened == ["t1"])
    }
}
