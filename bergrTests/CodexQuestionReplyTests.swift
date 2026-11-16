import Foundation
import Testing
import HerdrKit
@testable import bergr

@MainActor struct CodexQuestionReplyTests {
    @Test func selectsQuestionBeforePasting() async {
        var lines = ["An agent is working"]
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("src/example.swift", title: "Which file?", pendingCount: 1,
            lines: { lines }, previous: { actions.append("shift-left"); lines = ["↳ Re: Which file?"] },
            paste: { actions.append("paste:" + $0) }, submit: { actions.append("enter") }, settle: .zero)
        #expect(sent)
        #expect(actions == ["shift-left", "paste:src/example.swift", "enter"])
    }

    @Test func doesNotSendToAnUnmatchedQuestion() async {
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("answer", title: "Which file?", pendingCount: 2,
            lines: { ["Which file?", "↳ Re: A different question"] }, previous: { actions.append("shift-left") },
            paste: { actions.append($0) }, submit: { actions.append("enter") }, settle: .zero, selectionWait: .zero)
        #expect(!sent)
        #expect(actions == ["shift-left", "shift-left"])
    }

    @Test func asyncQuestionKeepsItsAnswerMetadata() {
        let feed = ChatFeed()
        feed.loadEvents([["t": "question", "id": "q", "title": "Which file?", "options": [], "async": true]])
        #expect(feed.questionInfo["q"]?.codexAsync == true)
        feed.applyDemo(["t": "question", "id": "q", "title": "Which file?", "options": [],
                        "async": true, "answer": "src/example.swift"])
        #expect(feed.questionInfo["q"]?.answer == "src/example.swift")
    }

    @Test func openQuestionIsTheNewestUnansweredAsyncOne() {
        let items: [(String, String)?] = [("q1", "First?"), nil, ("q2", "Second?"), ("q3", "Claude's?"), nil]
        let info: [String: (async: Bool, answered: Bool)] = [
            "q1": (true, false), "q2": (true, false), "q3": (false, false)]
        let open = CodexQuestionReply.open(items: items, info: { info[$0] }, picked: { _ in false })
        #expect(open?.id == "q2" && open?.title == "Second?")
        #expect(CodexQuestionReply.open(items: items, info: { info[$0] }, picked: { $0 == "q2" })?.id == "q1")
        let answered: [String: (async: Bool, answered: Bool)] = ["q1": (true, true), "q2": (true, true)]
        #expect(CodexQuestionReply.open(items: items, info: { answered[$0] }, picked: { _ in false }) == nil)
    }

    @Test func plainRepliesAnswerTheOpenQuestion() {
        #expect(CodexQuestionReply.answersQuestion(text: "Use SQLite", hasImages: false, sendAsNew: false))
        #expect(!CodexQuestionReply.answersQuestion(text: "Use SQLite", hasImages: false, sendAsNew: true))
        #expect(!CodexQuestionReply.answersQuestion(text: "Use SQLite", hasImages: true, sendAsNew: false))
        #expect(!CodexQuestionReply.answersQuestion(text: "!ls", hasImages: false, sendAsNew: false))
        #expect(!CodexQuestionReply.answersQuestion(text: "/compact", hasImages: false, sendAsNew: false))
    }

    @Test func notificationRepliesToCodexQuestionsGoToTheChat() throws {
        func status(app: String, kind: String? = nil) throws -> TerminalStatus {
            let kindJSON = kind.map { #","kind":"\#($0)""# } ?? ""
            return try JSONDecoder().decode(TerminalStatus.self,
                from: Data(#"{"state":"idle","app":"\#(app)"\#(kindJSON)}"#.utf8))
        }
        #expect(AnswerFlow.isCodexQuestion(status: try status(app: "codex"), alertQuestion: "Which db?"))
        #expect(AnswerFlow.isCodexQuestion(status: try status(app: "Codex", kind: "question"), alertQuestion: nil))
        #expect(!AnswerFlow.isCodexQuestion(status: try status(app: "codex"), alertQuestion: nil))
        #expect(!AnswerFlow.isCodexQuestion(status: try status(app: "claude"), alertQuestion: "Which db?"))
    }

    @Test func aLaterUserMessageClosesTheQuestion() {
        let items: [(String, String)?] = [("q1", "Which?"), nil, nil]
        let info: [String: (async: Bool, answered: Bool)] = ["q1": (true, false)]
        #expect(CodexQuestionReply.open(items: items, info: { info[$0] }, picked: { _ in false }, lastUserMessage: 1) == nil)
        #expect(CodexQuestionReply.open(items: items, info: { info[$0] }, picked: { _ in false }, lastUserMessage: nil)?.id == "q1")
    }
}

struct ConversationAlertsTests {
    @Test func newAlertReplacesOlderFinishedOnesOfTheSameConversation() {
        let info: [AnyHashable: Any] = ["host": "mac", "address": "t1"]
        let delivered: [(id: String, info: [AnyHashable: Any], category: String)] = [
            ("old-done", ["host": "mac", "address": "t1"], "reply"),
            ("old-question", ["host": "mac", "address": "t1"], AnswerCategory.identifier(for: AnswerQuestion(title: "Run?", options: ["Yes", "No"], keys: false)) ?? "x"),
            ("other-agent", ["host": "mac", "address": "t2"], "reply"),
            ("new", ["host": "mac", "address": "t1"], "reply"),
        ]
        #expect(ConversationAlerts.superseded(by: info, keeping: "new", among: delivered) == ["old-done"])
    }
}

struct MessageTimeRevealTests {
    @Test func leftOnlyAfterADeliberatePull() {
        #expect(MessageTimeReveal.clamp(40) == 0)
        #expect(MessageTimeReveal.clamp(-20) == 0)
        #expect(MessageTimeReveal.clamp(-70) == -40)
        #expect(MessageTimeReveal.clamp(-206) == -(MessageTimeReveal.width + 100 * 0.15))
    }

    @Test func labelShowsOnlyTheTimeForToday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let today = MessageTimeReveal.label(now.addingTimeInterval(-60), now: now, calendar: calendar)
        let older = MessageTimeReveal.label(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar)
        #expect(today.count < older.count)
    }
}

struct UsageHistoryChartTests {
    @Test func dropsMarkResetsAndSplitTheLine() {
        let t = Date(timeIntervalSince1970: 0)
        let e = [10.0, 40, 80, 2, 20].enumerated().map {
            UsageHistory.Entry(key: "k", time: t.addingTimeInterval(Double($0.offset) * 600), percent: $0.element)
        }
        #expect(UsageHistoryChart.resets(e) == [t.addingTimeInterval(1800)])
        #expect(UsageHistoryChart.segments(e).map(\.count) == [3, 2])
    }
}

struct ChangesFolderAndVerdictTests {
    @Test func workFolderFollowsEditsAndCd() {
        let edit = ChatFeed.Item(id: "1", kind: .tool(name: "Edit", summary: "/Users/me/src/app/a.swift"))
        let cd = ChatFeed.Item(id: "2", kind: .tool(name: "Bash", summary: "cd ~/src/bergr && just test"))
        let other = ChatFeed.Item(id: "3", kind: .tool(name: "Bash", summary: "ls"))
        #expect(ChangesSummary.workFolder(in: [edit, other], cwd: "/Users/me") == "/Users/me/src/app")
        #expect(ChangesSummary.workFolder(in: [edit, cd, other], cwd: "/Users/me") == "~/src/bergr")
        #expect(ChangesSummary.workFolder(in: [other], cwd: "/Users/me") == "/Users/me")
        #expect(ChangesModel.git("~/src/bergr", "status").hasPrefix(#"git -C ~/"src/bergr""#))
    }

    @Test func runnerSummaryBeatsStrayErrorWords() {
        #expect(TestRun.verdict("finish(id:error:): dropping\n✔ Test run with 686 tests in 117 suites passed after 10.2 seconds.") == .passed)
        #expect(TestRun.verdict("✘ Test run with 3 tests in 1 suite failed after 0.1 seconds with 1 issue.") == .failed)
        #expect(TestRun.verdict("Ran 80 tests in 11.0s\n\nOK") == .passed)
    }
}
