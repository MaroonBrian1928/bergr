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
}
