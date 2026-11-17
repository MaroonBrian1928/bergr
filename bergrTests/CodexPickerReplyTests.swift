import Foundation
import Testing
@testable import bergr

@MainActor struct CodexPickerReplyTests {
    private let title = "When a Codex choice fails, does the terminal show a “Re: …” reply composer, or a question panel with numbered choices?"
    private var panel: [String] {
        ["When a Codex choice fails, does the terminal show a “Re: …” reply", "composer, or a question panel with numbered choices?", "",
         "› 1. A “Re: …” reply composer", "  2. A panel with numbered choices",
         "  3. Not sure", "  4. Other", "", "enter submit  ^] skip  ⇧→ main prompt"]
    }

    @Test func choosesDigitWithoutPasteOrEnter() async {
        var screen = panel
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("A panel with numbered choices", title: title, pendingCount: 1,
            lines: { screen }, previous: { actions.append("previous") },
            paste: { actions.append("paste:" + $0) }, submit: { actions.append("enter") },
            choose: { actions.append(String($0)); screen = ["Next question?", "", "› 1. Yes", "  2. No", "", "enter submit  ^] skip  ⇧→ main prompt"] }, selectionWait: .milliseconds(20))
        #expect(sent)
        #expect(actions == ["2"])
    }

    @Test func firstChoicePreservesPunctuationAndWrap() async {
        var screen = panel
        screen[3] = "› 1. A “Re: …” reply"
        screen.insert("    composer", at: 4)
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("A “Re: …” reply composer", title: title, pendingCount: 1,
            lines: { screen }, previous: {}, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)); screen = ["Next question?", "", "› 1. Yes", "  2. No", "", "enter submit  ^] skip  ⇧→ main prompt"] })
        #expect(sent)
        #expect(actions == ["1"])
    }

    @Test func unrelatedFramesDoNotEndPolling() async {
        var reads = 0
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("Not sure", title: title, pendingCount: 1,
            lines: { reads += 1; return reads < 4 ? ["update \(reads)"] : (actions.contains("3") ? ["Next question?", "", "› 1. Yes", "  2. No", "", "enter submit  ^] skip  ⇧→ main prompt"] : panel) },
            previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)) },
            selectionWait: .milliseconds(300))
        #expect(sent)
        #expect(actions == ["previous", "3"])
    }

    @Test func lastQuestionAnsweredCountsWhenThePanelCloses() async {
        var actions: [String] = []
        var screen = panel
        let result = await CodexQuestionReply.sendResult("Not sure", title: title, pendingCount: 1,
            lines: { screen }, previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)); screen = ["› ", ""] },
            selectionWait: .milliseconds(500))
        #expect(result == .sent)
        #expect(actions == ["3"])
    }

    @Test func wrongHeadingAndTimeoutNeverSendExtraKeys() async {
        var actions: [String] = []
        let wrong = await CodexQuestionReply.send("Not sure", title: "Different question?", pendingCount: 1,
            lines: { panel }, previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)) }, selectionWait: .zero)
        #expect(!wrong)
        #expect(actions == ["previous"])
        actions = []
        let timedOut = await CodexQuestionReply.sendResult("Not sure", title: title, pendingCount: 1,
            lines: { panel }, previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)) }, selectionWait: .zero)
        #expect(timedOut == .unconfirmed)
        #expect(actions == ["3"])
    }
    @Test func cancellationDoesNotSendAdditionalKeys() async {
        var actions: [String] = []
        let task = Task { @MainActor in
            await CodexQuestionReply.sendResult("Not sure", title: title, pendingCount: 1,
                lines: { panel }, previous: { actions.append("previous") },
                paste: { _ in actions.append("paste") }, submit: { actions.append("enter") },
                choose: { actions.append(String($0)) }, selectionWait: .seconds(2))
        }
        await Task.yield()
        task.cancel()
        #expect((await task.value) != .sent)
        #expect(actions == ["3"] || actions.isEmpty)
    }

    @Test func historicalPanelDoesNotMaskCurrentComposer() async {
        var actions: [String] = []
        let sent = await CodexQuestionReply.send("answer", title: "Current question?", pendingCount: 1,
            lines: { panel + ["", "↳ Re: Current question?"] }, previous: { actions.append("previous") },
            paste: { actions.append($0) }, submit: { actions.append("enter") }, settle: .zero)
        #expect(sent)
        #expect(actions == ["answer", "enter"])
    }

    @Test func malformedFrameAfterDigitIsUnconfirmed() async {
        var screen = panel
        var actions: [String] = []
        let result = await CodexQuestionReply.sendResult("Not sure", title: title, pendingCount: 1,
            lines: { screen }, previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") }, choose: { actions.append(String($0)); screen = ["loading"] },
            selectionWait: .zero)
        #expect(result == .unconfirmed)
        #expect(actions == ["3"])
    }

    @Test func transcriptConfirmsCompletedSingleQuestion() async {
        var screen = panel
        var acknowledged = false
        var actions: [String] = []
        let result = await CodexQuestionReply.sendResult("Not sure", title: title, pendingCount: 1,
            lines: { screen }, previous: { actions.append("previous") }, paste: { _ in actions.append("paste") },
            submit: { actions.append("enter") },
            choose: { actions.append(String($0)); screen = ["normal prompt"]; acknowledged = true },
            confirmed: { acknowledged }, selectionWait: .zero)
        #expect(result == .sent)
        #expect(actions == ["3"])
    }

}
