import Foundation
import HerdrKit
import Testing
@testable import bergr

/// The demo's conversations: shaped like real sessions, and the same on every run.
@MainActor
struct DemoChatTests {
    private static let agents: [(address: String, agent: ChatAgent)] = [
        (DemoBeat.websiteAgent, .claude), (DemoBeat.totalsAgent, .claude), (DemoBeat.upgradeAgent, .codex),
        (DemoBeat.cacheAgent, .codex), (DemoBeat.flakyTestAgent, .antigravity),
    ]

    private func feed(_ conversation: DemoChat.Conversation) -> ChatFeed {
        let feed = ChatFeed()
        feed.loadDemo(conversation)
        return feed
    }

    private func status(_ state: String, title: String = "", msg: String? = nil) -> TerminalStatus {
        var fields: [String: String] = ["state": state, "title": title]
        fields["msg"] = msg
        return try! JSONDecoder().decode(TerminalStatus.self, from: JSONEncoder().encode(fields))
    }

    /// Runs of tool steps between two messages, as the chat groups them.
    private func runs(_ items: [ChatFeed.Item]) -> [[ChatFeed.Item]] {
        var out: [[ChatFeed.Item]] = [[]]
        for item in items {
            if case .tool = item.kind { out[out.count - 1].append(item) } else if !out[out.count - 1].isEmpty { out.append([]) }
        }
        return out.filter { !$0.isEmpty }
    }

    @Test func theFinishedTurnHasAnAskARepliesToolsAFailedStepAndAPassingTestRun() {
        let feed = feed(DemoChat.website)
        guard case .user(let ask) = feed.items.first?.kind else { Issue.record("starts with the ask"); return }
        #expect(ask.contains("dark mode toggle"))
        guard case .assistant(let last, _) = feed.items.last?.kind else { Issue.record("ends with the reply"); return }
        #expect(last.hasSuffix("Dark mode toggle is ready. It follows the system setting by default."))
        #expect(feed.items.contains { if case .assistant(let text, _) = $0.kind { text.contains("| File |") } else { false } })
        #expect(feed.items.contains { if case .plan(let steps) = $0.kind { steps.allSatisfy { $0.status == "completed" } } else { false } })
        // One step failed (the red "1 failed"), with its output.
        #expect(feed.toolFailed == [DemoChat.idPrefix + "b-t7"])
        #expect(feed.toolOutput[DemoChat.idPrefix + "b-t7"]?.contains("1 failed") == true)
        // Claude's commands carry a description first, then the command.
        let commands = feed.items.compactMap { item -> String? in
            if case .tool("Bash", let summary) = item.kind { summary } else { nil }
        }
        #expect(commands.contains("Run the tests\nnpm test"))
        #expect(commands.allSatisfy { $0.split(separator: "\n").count == 2 })
        #expect(feed.items.contains { if case .tool("Edit", _) = $0.kind { true } else { false } })
        #expect(TestRun.last(in: feed.items, output: feed.toolOutput)?.verdict == .passed)
    }

    @Test func everyMessageHasItsTime() {
        for (address, agent) in Self.agents {
            let feed = feed(DemoChat.conversation(address: address, agent: agent))
            let messages = feed.items.filter {
                switch $0.kind {
                case .user, .assistant: true
                default: false
                }
            }
            #expect(!messages.isEmpty)
            for message in messages { #expect(feed.sentAt[message.id] != nil, "\(message.id)") }
            let times = messages.compactMap { feed.sentAt[$0.id] }
            #expect(times == times.sorted(), "\(address): in order")
            #expect(times.allSatisfy { $0 <= DemoChat.start })
        }
    }

    /// Every run of steps has its staged line, and every long output that a finished run would be
    /// summed up by has one too: nothing is left for the model, so screenshots don't change.
    @Test func everySummaryIsStaged() {
        for (address, agent) in Self.agents {
            let conversation = DemoChat.conversation(address: address, agent: agent)
            let feed = feed(conversation)
            for stage in conversation.stages { for timed in stage.events { feed.applyDemo(timed.event) } }
            #expect(feed.items.allSatisfy { DemoChat.isDemo($0.id) }, "\(address): demo ids")
            let started = Set(feed.subagents.compactMap(\.parent))
            for run in runs(feed.items).map({ $0.filter { !started.contains($0.id) } }) where !run.isEmpty {
                if run.count > 1 { #expect(DemoChat.summaries["steps|" + run.last!.id] != nil, "\(run.last!.id): few words") }
                let digest = run.last { feed.toolFailed.contains($0.id) && feed.toolOutput[$0.id] != nil }
                    ?? run.last { feed.toolOutput[$0.id] != nil }
                if let digest, ToolOutputSummaries.isLong(feed.toolOutput[digest.id] ?? "") {
                    #expect(DemoChat.summaries[digest.id] != nil, "\(digest.id): output summary")
                }
            }
        }
        // A summary under a short output would show something the app doesn't do.
        #expect(DemoChat.summaries.count >= 20)
        #expect(DemoChat.summaries.values.allSatisfy { $0.split(separator: " ").count <= 12 })
    }

    @Test func stagedTextIsShownWithoutAskingTheModel() async {
        let writer = CountingWriter()
        let summaries = ToolOutputSummaries(writer: writer)
        let output = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let id = DemoChat.idPrefix + "b-t9"
        #expect(summaries.summary(for: id) == nil)
        summaries.seedDemo(DemoChat.summaries)
        #expect(summaries.summary(for: id) == "48 tests passed in 12 seconds")
        #expect(summaries.summary(for: "steps|" + DemoChat.idPrefix + "b-t8") == "Add the toggle and run the tests")
        // A demo step without a staged line stays without: the model is never asked for a demo id.
        await summaries.request(id: DemoChat.idPrefix + "other", finished: true, name: "Bash", command: "ls", output: output)
        await summaries.requestSteps(id: "steps|" + DemoChat.idPrefix + "other", titles: ["Ran ls", "Read a.swift"])
        #expect(await writer.count == 0)
        #expect(summaries.summary(for: DemoChat.idPrefix + "other") == nil)
        // Only demo ids can be seeded.
        summaries.seedDemo(["toolu_real": "nope"])
        #expect(summaries.summary(for: "toolu_real") == nil)
        // Anything else is still written by the model.
        await summaries.request(id: "toolu_real", finished: true, name: "Bash", command: "ls", output: output)
        #expect(await writer.count == 1)

        let chips = ReplySuggestions(writer: writer)
        chips.seedDemo(DemoChat.chips)
        #expect(chips.chips[DemoChat.idPrefix + "b-a6"] == ["Show me what changed", "Run it on the staging site"])
        await chips.request(messageID: DemoChat.idPrefix + "a-a3", text: "Shall I?", working: false)
        #expect(await writer.count == 1)
        #expect(DemoChat.chips.values.allSatisfy { $0.count <= ReplySuggestions.maxChips })
        #expect(DemoChat.chips.values.joined().allSatisfy { $0.split(separator: " ").count <= ReplySuggestions.maxWords })
    }

    @Test func thePermissionAgentFollowsItsTerminal() {
        let conversation = DemoChat.totals
        let feed = feed(conversation)
        // It waits with the command it wants to run as its last step.
        guard case .tool("Bash", let summary) = feed.items.last?.kind else { Issue.record("ends on the command"); return }
        #expect(summary.hasSuffix(DemoBeat.migrationCommand))
        #expect(conversation.stage(for: status("blocked", title: DemoBeat.migrationQuestion, msg: "Add order totals endpoint")) == nil)
        // The second prompt, seen first (the chat was closed meanwhile): the migration's stage comes before it.
        let second = conversation.stage(for: status("blocked", title: DemoBeat.dropQuestion, msg: "Add order totals endpoint"))
        #expect(second?.beat == DemoBeat.dropQuestion)
        #expect(second.map { conversation.chain(before: $0).map(\.beat) } == [DemoBeat.migrationRunning])
        for timed in second?.events ?? [] { feed.applyDemo(timed.event) }
        guard case .tool("Bash", let drop) = feed.items.last?.kind else { Issue.record("asks about the table"); return }
        #expect(drop.hasSuffix(DemoBeat.dropCommand))
        #expect(DangerousCommand.check(drop) != nil, "the second prompt is a dangerous one")
        #expect(DangerousCommand.check(DemoBeat.migrationCommand) == nil, "the first is not")
        #expect(DemoChat.explanation(for: DemoBeat.dropQuestion + "\n" + DemoBeat.dropCommand)?.contains("order_totals_old") == true)
        #expect(DemoChat.explanation(for: "rm -rf /") == nil)
        // A refusal has its own ending, without the migration's steps.
        let skipped = conversation.stage(for: status("idle", title: "Add order totals endpoint", msg: DemoBeat.migrationSkipped))
        #expect(skipped.map { conversation.chain(before: $0).isEmpty } == true)
    }

    @Test func codexAsksAnAsyncQuestionTheReplyBoxAnswers() {
        let feed = feed(DemoChat.cache)
        guard case .question(let title, let options) = feed.items.last?.kind else { Issue.record("ends on the question"); return }
        #expect(title == DemoBeat.cacheQuestion)
        #expect(options == ["On disk", "In Redis"])
        #expect(feed.questionInfo[DemoChat.cacheQuestion]?.codexAsync == true)
        let open = CodexQuestionReply.open(
            items: feed.items.map { item in
                if case .question(let title, _) = item.kind { return (item.id, title) }
                return nil
            },
            info: { id in feed.questionInfo[id].map { ($0.codexAsync, $0.answer != nil) } }, picked: { _ in false },
            lastUserMessage: feed.items.lastIndex { if case .user = $0.kind { true } else { false } })
        #expect(open?.title == DemoBeat.cacheQuestion)
        // The reply finds the question on the demo terminal's screen, as on Codex's.
        #expect(CodexQuestionReply.selected(title: title, lines: ["  On disk · In Redis", "", "  Re: " + DemoBeat.cacheQuestion, "› "]))
    }

    @Test func theWorkingAgentRunsThroughItsStagesAndFinishes() {
        let conversation = DemoChat.upgrade
        let feed = feed(conversation)
        #expect(feed.subagents.count == 2)
        #expect(feed.runningSubagents == 2)
        #expect(DemoChat.runningSubagents(address: DemoBeat.upgradeAgent,
                                          status: status("working", title: "Upgrade Postgres to 18", msg: DemoBeat.upgradeChecks)) == 2)
        #expect(DemoChat.runningSubagents(address: DemoBeat.websiteAgent, status: status("done")) == 0)
        // No empty bubble for a sub-agent: they live beside the conversation.
        #expect(!feed.items.contains { if case .assistant("", _) = $0.kind { true } else { false } })
        let done = conversation.stage(for: status("done", title: "Upgraded Postgres to 18", msg: DemoBeat.upgradeDone))
        #expect(done.map { conversation.chain(before: $0).map(\.beat) }
            == [DemoBeat.upgradeChecks, DemoBeat.upgradeRunning, DemoBeat.upgradeTests])
        for stage in conversation.stages { for timed in stage.events { feed.applyDemo(timed.event) } }
        #expect(feed.runningSubagents == 0)
        guard case .assistant(let text, _) = feed.items.last?.kind else { Issue.record("ends with the reply"); return }
        #expect(text.contains("Postgres 18.1"))
        #expect(feed.items.contains { if case .plan(let steps) = $0.kind { steps.allSatisfy { $0.status == "completed" } } else { false } })
        #expect(feed.items.contains { if case .note = $0.kind { true } else { false } })
    }

    @Test func commandsAndUsageComeWithTheConversation() {
        let claude = feed(DemoChat.website)
        #expect(CommandMatcher.matches(claude.commands, draft: "/co").map(\.name) == ["/compact", "/context"])
        #expect(claude.usage?.fraction == 0.4)
        #expect(claude.usage?.session?.percent == 62)
        #expect(claude.usage?.weekly?.percent == 41)
        let codex = feed(DemoChat.upgrade)
        #expect(CommandMatcher.matches(codex.commands, draft: "$").map(\.name) == ["$db-migration", "$release-notes"])
        #expect(codex.usage?.session?.percent == 18)
        #expect(codex.usage?.weekly == nil)
        // The Usage screen reads the same numbers without the chat open.
        #expect(DemoChat.usage(address: DemoBeat.websiteAgent, agent: .claude) == claude.usage)
        // Nothing in the demo is near a limit: it must never alert.
        for (address, agent) in Self.agents {
            let usage = DemoChat.usage(address: address, agent: agent)
            #expect((usage?.fraction ?? 0) < ContextWarning.threshold)
            #expect((usage?.session?.percent ?? 0) < UsageAlertTracker.threshold)
            #expect((usage?.weekly?.percent ?? 0) < UsageAlertTracker.threshold)
        }
    }

    @Test func usageHistoryDrawsTwoResetsAndForecastsTheLimit() {
        let history = UsageHistory(url: nil)
        history.seedDemo(DemoChat.history(machine: "studio", agent: .claude) + DemoChat.history(machine: "buildbox", agent: .codex))
        history.seedDemo(DemoChat.history(machine: "studio", agent: .claude))
        #expect(history.entries.isEmpty, "the made-up history is never among what is saved")
        let key = UsageHistory.key(machine: "studio", agent: "claude", kind: "session")
        let week = history.entries(key: key, since: DemoChat.start.addingTimeInterval(-7 * 86_400))
        #expect(UsageHistoryChart.resets(week).count == 2)
        #expect(history.entries(key: key, since: DemoChat.start.addingTimeInterval(-86_400)).count >= 2)
        let window = ChatFeed.Usage.Window(percent: DemoChat.claudeSession,
                                           resetsAt: Date(timeIntervalSince1970: DemoChat.claudeSessionReset))
        guard case .hitsLimit(let at) = history.forecast(key: key, window: window, now: DemoChat.start) else {
            Issue.record("the session is forecast to hit its limit before it resets")
            return
        }
        #expect(at > DemoChat.start && at < Date(timeIntervalSince1970: DemoChat.claudeSessionReset))
        let weekly = history.entries(key: UsageHistory.key(machine: "studio", agent: "claude", kind: "weekly"),
                                     since: DemoChat.start.addingTimeInterval(-7 * 86_400))
        #expect(UsageHistoryChart.resets(weekly).count == 1)
        #expect(weekly.allSatisfy { (0...100).contains($0.percent) })
    }

    @Test func twoAgentsOnOneMachineNameItOnce() {
        #expect(UsageScreen.header(agent: "Claude", machines: ["studio", "studio"]) == "Claude on studio")
        #expect(UsageScreen.header(agent: "Claude", machines: ["studio"]) == "Claude on studio")
        #expect(UsageScreen.header(agent: "Codex", machines: ["studio", "buildbox", "studio"]) == "Codex · studio, buildbox")
    }

    @Test func theDemoIsThreeMachinesAddedOnce() {
        let defaults = UserDefaults(suiteName: "demo-chat-tests-\(UUID().uuidString)")!
        let store = HostStore(defaults: defaults)
        let first = store.addDemo()
        #expect(first.demoMachine == .studio)
        #expect(store.addDemo().id == first.id)
        #expect(store.hosts.map(\.name) == ["studio", "buildbox", "winbook"])
        #expect(store.hosts.filter(\.isDemo).count == 3)
    }

    @Test func theDemoMachinesAnswerTheGitCommandsTheAppRuns() throws {
        // Only the worktree's row names its branch.
        let branch = try DemoChat.commandOutput(Worktrees.branchCommand(cwd: DemoBeat.cacheWorktree, windows: false))
        #expect(Worktrees.parseBranchInfo(branch) == Worktrees.BranchInfo(branch: "codex/cache-images", isLinkedWorktree: true))
        #expect(throws: DemoChat.NoAnswer.self) {
            try DemoChat.commandOutput(Worktrees.branchCommand(cwd: DemoBeat.website, windows: false))
        }
        // The Changes sheet: branch, 20 files, and the header's diff.
        let status = GitParsing.status(try DemoChat.commandOutput(ChangesModel.git(DemoBeat.website, "status --porcelain=v1 -b")))
        #expect(status.branch == "feature/dark-mode")
        let stat = GitParsing.stat(try DemoChat.commandOutput(ChangesModel.diffStatCommand(folder: DemoBeat.website, base: "HEAD")))
        #expect(stat.files.count == 20)
        #expect(stat.files.first?.path == "src/components/Header.tsx")
        let diff = GitParsing.diff(try DemoChat.commandOutput(
            ChangesModel.fileDiffCommand(folder: DemoBeat.website, base: "HEAD", path: "src/components/Header.tsx")))
        #expect(diff.hunks.flatMap(\.lines).contains { $0.kind == .add && $0.text.contains("<ThemeToggle />") })
        #expect(DemoChat.changesSummary(folder: DemoBeat.website) != nil)
        #expect(DemoChat.changesSummary(folder: DemoBeat.shopAPI) == nil)
        // Nothing else runs on a demo machine.
        #expect(throws: DemoChat.NoAnswer.self) { try DemoChat.commandOutput("uname -a") }
    }

    @Test func theAwayCardHasItsSentences() {
        #expect(DemoChat.digest[DemoBeat.websiteAgent] == "Dark mode toggle is ready; 20 files changed, tests pass")
        #expect(DemoChat.digest[DemoBeat.totalsAgent] == "Wants to run the orders migration")
    }
}

private actor CountingWriter: OnDeviceTextWriting {
    private(set) var count = 0

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        count += 1
        return "Six tests passed"
    }
}
