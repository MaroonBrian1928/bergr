import Testing
@testable import bergr

struct CursorMenuTests {
    private let prompt = [
        " Computer Use wants to control these apps",
        "",
        " │ Check the new working animations in the Bergr Mac app.",
        "",
        "   ◉ Bergr Mac Dev",
        "",
        " 14 other apps will be hidden while Claude works.",
        "",
        " ❯ Deny, and tell Claude what to do differently (esc)",
        "   Allow for this session (1 app)",
        "",
        " Enter to confirm · Esc to cancel",
    ]

    @Test func unnumberedMenuIsRead() {
        let choices = AnswerParser.choices(in: prompt)
        #expect(choices.map(\.label) == ["Deny, and tell Claude what to do differently (esc)", "Allow for this session (1 app)"])
        #expect(choices.map(\.selected) == [true, false])
        #expect(AnswerParser.question(in: prompt) == "14 other apps will be hidden while Claude works.")
    }

    @Test func arrowsFromTheCursorToTheOption() {
        let choices = AnswerParser.choices(in: prompt)
        #expect(AnswerParser.steps(to: choices[1], in: choices) == 1)
    }

    @Test func anAgentsInputPromptIsNotAMenu() {
        #expect(AnswerParser.choices(in: ["─────", "❯ fix the tests", "─────", "  ? for shortcuts"]).isEmpty)
        #expect(AnswerParser.choices(in: ["─────", "❯ ", "─────"]).isEmpty)
    }

    @Test func numberedMenusStillWin() {
        let lines = ["Do you want to proceed?", "❯ 1. Yes", "  2. No"]
        #expect(AnswerParser.choices(in: lines).map(\.number) == [1, 2])
    }
}
