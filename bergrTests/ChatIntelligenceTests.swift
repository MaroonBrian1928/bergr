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
    private func plan(_ status: ReplySuggestionStatus = .unfinished, evidence: String = "The export test still fails on UTC dates.",
                      choices: [String] = [], reply: String = "Fix UTC date handling") -> ReplySuggestionPlan {
        ReplySuggestionPlan(requestedWork: "Fix the export", status: status, evidence: evidence,
                            choices: choices, nextReply: reply)
    }

    private func encoded(_ plan: ReplySuggestionPlan) -> String {
        String(decoding: try! JSONEncoder().encode(plan), as: UTF8.self)
    }

    @Test func parsesTrimmedLinesAndCapsAtTwo() {
        #expect(ReplySuggestions.parse("- Run the tests\n\"Commit it\"\nExplain the change") == ["Run the tests", "Commit it"])
    }

    @Test func dropsLongLinesDuplicatesAndNoSuggestionSentinel() {
        let reply = """
        This suggestion is far too long to fit into a useful reply chip
        NONE
        Run the tests
        run the tests
        1. Commit it
        """
        #expect(ReplySuggestions.parse(reply) == ["Run the tests", "Commit it"])
        #expect(ReplySuggestions.parse("  \n \n").isEmpty)
    }

    @Test func completeWorkNeverProducesBusywork() {
        let p = plan(.complete, evidence: "All tests pass.", reply: "Run the tests again")
        #expect(ReplySuggestions.validated(p, text: "All tests pass.", userRequest: "Fix the export").isEmpty)
    }

    @Test func rejectsInventedEvidenceAndCompletedEvidence() {
        #expect(ReplySuggestions.validated(plan(), text: "Everything is done.", userRequest: "Fix the export").isEmpty)
        let p = plan(evidence: "The dashboard is complete and running locally.", reply: "Check the local build status")
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Build locally; do not deploy.").isEmpty)
    }

    @Test func unfinishedWorkProducesOneActionNotTwoParaphrases() {
        let p = plan(evidence: "The beta build is still processing.", reply: "Check beta processing status\nConfirm beta processing status")
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Upload the beta") == ["Check beta processing status"])
    }

    @Test func offeredChoicesMustBeInTheActualQuestion() {
        let p = plan(.question, evidence: "SQLite or Postgres?", choices: ["SQLite", "MongoDB"])
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Add persistent storage") == ["SQLite"])
    }

    @Test func unrequestedPublishingAndCancellationAreRejected() {
        let p = plan(evidence: "The release notes still need updating and committing.", reply: "Update release notes and commit them")
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Update the release notes") == ["Update release notes"])
        let onlyCommit = plan(evidence: p.evidence, reply: "Commit the release notes")
        #expect(ReplySuggestions.validated(onlyCommit, text: onlyCommit.evidence, userRequest: "Update the release notes").isEmpty)
        let cancel = plan(evidence: "The beta is still processing.", reply: "Cancel the beta upload")
        #expect(ReplySuggestions.validated(cancel, text: cancel.evidence, userRequest: "Upload the beta").isEmpty)
    }

    @Test func explicitPermissionsAndNegativeConstraintsAreRespected() {
        let p = plan(evidence: "The changes have not been committed or pushed.", reply: "Commit and push the changes")
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Commit and push the changes") == [p.nextReply])
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Do not commit or push").isEmpty)
        #expect(ReplySuggestions.validated(p, text: p.evidence, userRequest: "Commit and push eventually. Do not commit or push yet.").isEmpty)
        let deployment = plan(evidence: "Deployment is pending.", reply: "Deploy the dashboard")
        #expect(ReplySuggestions.validated(deployment, text: deployment.evidence, userRequest: "Build locally. Don't deploy.").isEmpty)
    }

    @Test func writesChoicesForAFinishedMessageOnce() async {
        let p = plan(.question, evidence: "SQLite or Postgres?", choices: ["SQLite", "Postgres"])
        let writer = FakeWriter(reply: encoded(p))
        let suggestions = ReplySuggestions(writer: writer)
        for _ in 0..<2 {
            await suggestions.request(messageID: "m1", text: p.evidence, working: false, userRequest: "Add persistent storage")
        }
        #expect(suggestions.chips["m1"] == ["SQLite", "Postgres"])
        #expect(await writer.calls == 1)
    }

    @Test func malformedModelOutputDoesNotBecomeAChip() async {
        let suggestions = ReplySuggestions(writer: FakeWriter(reply: "Run notification tests\nTest notification delivery"))
        await suggestions.request(messageID: "bad", text: "The beta is still processing.", working: false)
        #expect(suggestions.chips["bad"] == nil)
    }

    @Test func promptKeepsLatestUserGoalSeparateFromProgressAndPreservesAgentEnding() async {
        let writer = FakeWriter(reply: nil)
        let suggestions = ReplySuggestions(writer: writer)
        await suggestions.request(messageID: "context", text: "Fixed the login loop.", working: false,
                                  context: String(repeating: "Agent: compiling\n", count: 300),
                                  userRequest: "Fix login; do not commit.")
        let prompt = await writer.lastPrompt
        #expect(prompt?.contains("USER'S LATEST REQUEST:\nFix login; do not commit.") == true)
        #expect(prompt?.contains("Fixed the login loop") == true)
        let long = String(repeating: "details ", count: 600) + "Which cache strategy do you prefer?"
        #expect(ReplySuggestions.prompt(text: long, context: "").contains("Which cache strategy do you prefer?"))
    }

    @Test func noChipsWhileTheAgentWorks() async {
        let writer = FakeWriter(reply: nil)
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
