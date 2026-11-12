import Foundation
import Testing
@testable import bergr

/// Records the prompts it gets and answers with a fixed reply (nil: it can't write).
private actor FakeWriter: OnDeviceTextWriting {
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []
    private let reply: String?

    init(reply: String?) { self.reply = reply }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        self.instructions.append(instructions)
        prompts.append(prompt)
        return reply
    }
}

/// Records every git command the model runs.
private actor CommandLog {
    private(set) var commands: [String] = []
    func add(_ command: String) { commands.append(command) }
}

private let statText = """
 Sources/Auth.swift | 12 ++++++----
 Tests/AuthTests.swift | 4 ++++
 2 files changed, 14 insertions(+), 4 deletions(-)
"""

private func fakeRun(log: CommandLog, diff: String) -> ChangesModel.Runner {
    { command in
        await log.add(command)
        if command.contains("status --porcelain") { return "## main...origin/main\n M Sources/Auth.swift\n" }
        if command.contains("--stat") { return statText }
        if command.hasSuffix("--no-ext-diff") { return diff }
        return ""
    }
}

@MainActor
struct ChangesSummaryTests {
    private func summaryFromModel(writer: FakeWriter, expensive: Bool, reply: String? = nil,
                                  diff: String = "diff --git a/x b/x\n+added") async -> (ChangesModel, CommandLog) {
        let log = CommandLog()
        let model = ChangesModel(folder: "/repo", expensive: expensive, lastReply: reply, writer: writer,
                                 run: fakeRun(log: log, diff: diff))
        await model.load()
        await model.summaryTask?.value
        return (model, log)
    }

    @Test func promptHasStatDiffHeadAndReply() {
        let prompt = ChangesSummary.prompt(stat: statText, diffHead: "+added line", reply: "I refactored auth.")
        #expect(prompt?.contains("Diff stat:") == true && prompt?.contains("Auth.swift") == true)
        #expect(prompt?.contains("First lines of the diff:\n+added line") == true)
        #expect(prompt?.contains("The agent's last reply:\nI refactored auth.") == true)
    }

    @Test func promptWithoutDiffOrReplyHasOnlyStat() {
        let prompt = ChangesSummary.prompt(stat: statText, diffHead: "", reply: nil)
        #expect(prompt?.contains("Diff stat:") == true)
        #expect(prompt?.contains("First lines") == false && prompt?.contains("last reply") == false)
    }

    @Test func nothingToSummariseGivesNoPrompt() {
        #expect(ChangesSummary.prompt(stat: "  \n", diffHead: "", reply: "  ") == nil)
    }

    @Test func diffHeadKeepsFirst120Lines() {
        let diff = (1...300).map { "line \($0)" }.joined(separator: "\n")
        let head = ChangesSummary.diffHead(diff)
        #expect(head.split(separator: "\n").count == 120)
        #expect(head.hasSuffix("line 120"))
        #expect(!head.contains("line 121\n"))
    }

    @Test func promptTruncatesLongInputs() {
        let longStat = String(repeating: "s", count: 10_000)
        let longReply = String(repeating: "r", count: 10_000)
        let prompt = ChangesSummary.prompt(stat: longStat, diffHead: "", reply: longReply) ?? ""
        #expect(prompt.count < ChangesSummary.statLimit + ChangesSummary.replyLimit + 200)
        #expect(prompt.contains("…"))
    }

    @Test func lastReplyIsTheLatestAssistantText() {
        let items: [ChatFeed.Item] = [
            .init(id: "1", kind: .assistant(text: "first", blocks: [])),
            .init(id: "2", kind: .tool(name: "Bash", summary: "ls")),
            .init(id: "3", kind: .assistant(text: "  ", blocks: [])),
            .init(id: "4", kind: .assistant(text: "latest", blocks: [])),
        ]
        #expect(ChangesSummary.lastReply(in: items) == "latest")
        #expect(ChangesSummary.lastReply(in: []) == nil)
    }

    @Test func writtenSummaryIsShownAndPromptReachesWriter() async {
        let writer = FakeWriter(reply: "Refactors the auth middleware and adds a redirect test.")
        let (model, _) = await summaryFromModel(writer: writer, expensive: false, reply: "Done.")
        #expect(model.summary == .written("Refactors the auth middleware and adds a redirect test."))
        let prompts = await writer.prompts
        #expect(prompts.count == 1)
        #expect(prompts[0].contains("Auth.swift"))
        #expect(prompts[0].contains("+added"))
        #expect(prompts[0].contains("Done."))
        #expect(await writer.instructions == [ChangesSummary.instructions])
    }

    @Test func nilFromWriterHidesTheRow() async {
        let writer = FakeWriter(reply: nil)
        let (model, _) = await summaryFromModel(writer: writer, expensive: false)
        #expect(model.summary == .none)
        #expect(await writer.prompts.count == 1)
    }

    @Test func expensiveNetworkUsesStatAndReplyOnly() async {
        let writer = FakeWriter(reply: "Adds a redirect test.")
        let (model, log) = await summaryFromModel(writer: writer, expensive: true, reply: "Added a test.")
        #expect(model.summary == .written("Adds a redirect test."))
        let prompt = await writer.prompts.first ?? ""
        #expect(prompt.contains("Diff stat:") && prompt.contains("The agent's last reply:"))
        #expect(!prompt.contains("First lines of the diff"))
        let commands = await log.commands
        #expect(!commands.contains { $0.hasSuffix("--no-ext-diff") })
        #expect(!commands.contains { $0.contains("-- \"") })
    }

    @Test func noChangesAndNoReplySkipsTheWriter() async {
        let writer = FakeWriter(reply: "unused")
        let log = CommandLog()
        let model = ChangesModel(folder: "/repo", expensive: false, lastReply: nil, writer: writer) { command in
            await log.add(command)
            if command.contains("status --porcelain") { return "## main\n" }
            return ""
        }
        await model.load()
        await model.summaryTask?.value
        #expect(model.summary == .none)
        #expect(await writer.prompts.isEmpty)
    }
}
