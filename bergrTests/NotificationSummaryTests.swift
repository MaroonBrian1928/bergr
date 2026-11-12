import Foundation
import Testing
@testable import bergr

/// Records the prompts a writer was asked, and answers with a fixed reply.
actor PromptRecorder {
    private(set) var prompts: [String] = []
    func add(_ prompt: String) { prompts.append(prompt) }
}

struct FakeSummaryWriter: OnDeviceTextWriting {
    let reply: String?
    let recorder: PromptRecorder

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        await recorder.add(prompt)
        return reply
    }
}

struct NotificationSummaryTests {
    private func chat(_ count: Int) -> [ChatFeed.Item] {
        (1...count).map { ChatFeed.Item(id: "i\($0)", kind: .user("message \($0)")) }
    }

    @Test func summaryReplacesTheBodyWhenTheModelAnswers() async {
        let recorder = PromptRecorder()
        let writer = FakeSummaryWriter(reply: "Fixed the login redirect; 3 files changed, tests pass", recorder: recorder)
        let body = await NotificationSummary.body(
            agent: "api", kind: .finished, transcript: NotificationSummary.transcript(chat(2)),
            fallback: "status text", writer: writer)
        #expect(body == "Fixed the login redirect; 3 files changed, tests pass")
        #expect(await recorder.prompts.count == 1)
    }

    @Test func fallbackWhenTheModelGivesNothing() async {
        let recorder = PromptRecorder()
        let writer = FakeSummaryWriter(reply: nil, recorder: recorder)
        let body = await NotificationSummary.body(
            agent: "api", kind: .needsYou, transcript: NotificationSummary.transcript(chat(2)),
            fallback: "Run rm?", writer: writer)
        #expect(body == "Run rm?")
    }

    @Test func noChatKeepsTheFallbackWithoutAskingTheModel() async {
        let recorder = PromptRecorder()
        let writer = FakeSummaryWriter(reply: "should not be used", recorder: recorder)
        let body = await NotificationSummary.body(
            agent: "api", kind: .error, transcript: [], fallback: "boom", writer: writer)
        #expect(body == "boom")
        #expect(await recorder.prompts.isEmpty)
    }

    @Test func promptUsesOnlyTheLastItems() {
        let lines = NotificationSummary.transcript(chat(20))
        #expect(lines.count == NotificationSummary.window)
        let prompt = NotificationSummary.prompt(agent: "api", kind: .finished, transcript: lines)
        #expect(prompt.contains("User: message 20"))
        #expect(prompt.contains("User: message 9"))
        #expect(!prompt.contains("User: message 8\n"))
        #expect(!prompt.contains("User: message 1\n"))
    }

    @Test func longItemsAreTruncated() {
        let long = String(repeating: "x", count: 5000)
        let lines = NotificationSummary.transcript([ChatFeed.Item(id: "a", kind: .assistant(text: long, blocks: []))])
        #expect(lines.count == 1)
        #expect(lines[0].count <= NotificationSummary.lineCharacters + 1)
        #expect(lines[0].hasSuffix("…"))

        let many = (0..<NotificationSummary.window).map { _ in long }
        let prompt = NotificationSummary.prompt(agent: "api", kind: .finished, transcript: many)
        #expect(prompt.count < NotificationSummary.promptCharacters + 500)
        #expect(prompt.contains("…"))
    }

    @Test func imagesAndPlaceholdersAreLeftOut() {
        let items = [
            ChatFeed.Item(id: "a", kind: .imageLoading(width: nil, height: nil, fromUser: false)),
            ChatFeed.Item(id: "b", kind: .user("hello")),
        ]
        #expect(NotificationSummary.transcript(items) == ["User: hello"])
    }
}
