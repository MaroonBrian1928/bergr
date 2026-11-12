import Foundation
import Testing
@testable import bergr

/// Answers with a fixed reply and counts the calls.
private actor FakeWriter: OnDeviceTextWriting {
    private let reply: String?
    private(set) var calls = 0
    private(set) var lastPrompt: String?

    init(reply: String?) { self.reply = reply }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        calls += 1
        lastPrompt = prompt
        return reply
    }
}

private let fiveLines = "a\nb\nc\nd\ne"
private let fourLines = "a\nb\nc\nd"

@MainActor
struct ToolOutputSummaryTests {
    @Test func longOutputOfAFinishedToolGetsOneLine() async {
        let writer = FakeWriter(reply: "Ran 214 tests, 2 failed: test_auth_redirect, test_logout")
        let summaries = ToolOutputSummaries(writer: writer)
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "swift test", output: fiveLines)
        #expect(summaries.summary(for: "t1") == "Ran 214 tests, 2 failed: test_auth_redirect, test_logout")
        #expect(await writer.calls == 1)
    }

    @Test func fourLinesOrFewerGetNoSummaryAndNoCall() async {
        let writer = FakeWriter(reply: "should not be used")
        let summaries = ToolOutputSummaries(writer: writer)
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "ls", output: fourLines)
        #expect(summaries.summary(for: "t1") == nil)
        #expect(await writer.calls == 0)
        #expect(!ToolOutputSummaries.isLong(fourLines))
        #expect(ToolOutputSummaries.isLong(fiveLines))
    }

    @Test func trailingNewlinesDontCountAsLines() {
        #expect(!ToolOutputSummaries.isLong(fourLines + "\n\n\n"))
    }

    @Test func runningToolGetsNoSummary() async {
        let writer = FakeWriter(reply: "Ran something")
        let summaries = ToolOutputSummaries(writer: writer)
        await summaries.request(id: "t1", finished: false, name: "Bash", command: "swift test", output: fiveLines)
        #expect(summaries.summary(for: "t1") == nil)
        #expect(await writer.calls == 0)
    }

    @Test func eachToolIsAskedOnce() async {
        let writer = FakeWriter(reply: "Ran tests")
        let summaries = ToolOutputSummaries(writer: writer)
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "swift test", output: fiveLines)
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "swift test", output: fiveLines)
        #expect(await writer.calls == 1)
        #expect(summaries.summary(for: "t1") == "Ran tests")
    }

    @Test func nilFromTheModelLeavesTheRowAsItWas() async {
        let summaries = ToolOutputSummaries(writer: FakeWriter(reply: nil))
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "swift test", output: fiveLines)
        #expect(summaries.summary(for: "t1") == nil)
    }

    @Test func summaryIsOneTrimmedLine() async {
        let writer = FakeWriter(reply: "\"Ran 3 tests, all passed\"\nsecond line that is dropped")
        let summaries = ToolOutputSummaries(writer: writer)
        await summaries.request(id: "t1", finished: true, name: "Bash", command: "swift test", output: fiveLines)
        #expect(summaries.summary(for: "t1") == "Ran 3 tests, all passed")
    }
}

@MainActor
struct ReplySuggestionTests {
    @Test func parsesOneChipPerLineTrimmed() {
        let reply = """
        - Run the tests
        "Commit it"
        Explain the change
        Fourth one
        """
        #expect(ReplySuggestions.parse(reply) == ["Run the tests", "Commit it", "Explain the change"])
    }

    @Test func dropsLongLinesAndDuplicates() {
        let reply = """
        This is a very long suggestion with too many words
        Run the tests
        run the tests
        1. Commit it
        """
        #expect(ReplySuggestions.parse(reply) == ["Run the tests", "Commit it"])
    }

    @Test func emptyReplyGivesNoChips() {
        #expect(ReplySuggestions.parse("  \n \n").isEmpty)
    }

    @Test func writesChipsForAFinishedMessageOnce() async {
        let writer = FakeWriter(reply: "Run the tests\nCommit it")
        let suggestions = ReplySuggestions(writer: writer)
        await suggestions.request(messageID: "m1", text: "All done.", working: false)
        await suggestions.request(messageID: "m1", text: "All done.", working: false)
        #expect(suggestions.chips["m1"] == ["Run the tests", "Commit it"])
        #expect(await writer.calls == 1)
    }

    @Test func listWriterPreservesAllSuggestions() {
        let output = "Review the auth changes\nCheck callback edge cases"
        #expect(FoundationModelsWriter.usable(output, preserveLines: true) == output)
        #expect(FoundationModelsWriter.usable(output, preserveLines: false) == "Review the auth changes")
    }

    @Test func promptIncludesUserConstraintsAndLatestEnding() async {
        let writer = FakeWriter(reply: "Review the auth changes\nCheck callback edge cases")
        let suggestions = ReplySuggestions(writer: writer)
        await suggestions.request(messageID: "context", text: "Fixed the login loop.", working: false,
                                  context: "User: Fix login; do not commit.")
        let prompt = await writer.lastPrompt
        #expect(prompt?.contains("do not commit") == true)
        #expect(prompt?.contains("Fixed the login loop") == true)
        #expect(suggestions.chips["context"]?.count == 2)
        let long = String(repeating: "details ", count: 600) + "Which cache strategy do you prefer?"
        #expect(ReplySuggestions.prompt(text: long, context: "").contains("Which cache strategy do you prefer?"))
    }

    @Test func noChipsWhileTheAgentWorks() async {
        let writer = FakeWriter(reply: "Run the tests")
        let suggestions = ReplySuggestions(writer: writer)
        await suggestions.request(messageID: "m1", text: "Working on it", working: true)
        #expect(suggestions.chips["m1"] == nil)
        #expect(await writer.calls == 0)
    }

    @Test func nilFromTheModelGivesNoChips() async {
        let suggestions = ReplySuggestions(writer: FakeWriter(reply: nil))
        await suggestions.request(messageID: "m1", text: "All done.", working: false)
        #expect(suggestions.chips["m1"] == nil)
    }
}
