import Foundation
import Testing
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
}
