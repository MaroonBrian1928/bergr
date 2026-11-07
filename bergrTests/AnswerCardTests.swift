import Testing
@testable import bergr

struct AnswerCardTests {
    static let claude = [
        "● Running git push",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for git commands in /home/x",
        "   3. No, and tell Claude what to do differently (esc)",
    ]
    static let boxed = [
        "╭──────────────────╮",
        "│ Do you want to proceed? │",
        "│ ❯ 1. Yes                │",
        "│   2. No                 │",
        "╰──────────────────╯",
    ]
    static let codex = [
        "  Allow command?",
        "",
        "  › 1. Yes, proceed (y)",
        "    2. Yes, and don't ask again for this command (a)",
        "    3. No, and tell Codex what to do differently (esc)",
    ]

    @Test func claudePrompt() {
        let c = AnswerParser.choices(in: Self.claude)
        #expect(c.map(\.number) == [1, 2, 3])
        #expect(c.map(\.selected) == [true, false, false])
        #expect(c[0].label == "Yes")
        #expect(AnswerParser.question(in: Self.claude) == "Do you want to proceed?")
    }

    @Test func boxedPrompt() {
        let c = AnswerParser.choices(in: Self.boxed)
        #expect(c == [AnswerChoice(number: 1, label: "Yes", selected: true), AnswerChoice(number: 2, label: "No", selected: false)])
        #expect(AnswerParser.question(in: Self.boxed) == "Do you want to proceed?")
    }

    @Test func codexPrompt() {
        let c = AnswerParser.choices(in: Self.codex)
        #expect(c.map(\.number) == [1, 2, 3])
        #expect(c[0].selected && !c[1].selected)
        #expect(c[0].label == "Yes, proceed (y)")
        #expect(AnswerParser.question(in: Self.codex) == "Allow command?")
    }

    @Test func noMarkers() {
        let c = AnswerParser.choices(in: ["Pick?", "1. A", "2. B"])
        #expect(c.map(\.selected) == [false, false])
    }

    @Test func emptyWhenNotStartingAtOneOrNoList() {
        #expect(AnswerParser.choices(in: ["Q", "2. A", "3. B"]).isEmpty)
        #expect(AnswerParser.choices(in: ["just text", "version 1.2"]).isEmpty)
        #expect(AnswerParser.question(in: ["just text"]) == nil)
    }

    @Test func bottomMostListWins() {
        let lines = ["Here are options:", "1. Apples", "2. Pears", "3. Plums", "", "Proceed?", "❯ 1. Yes", "  2. No"]
        #expect(AnswerParser.choices(in: lines).map(\.label) == ["Yes", "No"])
        #expect(AnswerParser.question(in: lines) == "Proceed?")
    }

    @Test func staleQuestionIsDetected() {
        let yes = AnswerChoice(number: 1, label: "Yes", selected: true)
        #expect(AnswerParser.isStillShown(yes, in: Self.claude))
        #expect(!AnswerParser.isStillShown(yes, in: Self.codex))
        #expect(!AnswerParser.isStillShown(yes, in: ["$ ls"]))
        #expect(!AnswerParser.isStillShown(yes, in: ["Q?", "1. Sure", "2. No"]))
    }

    @Test func arrowSteps() {
        let c = AnswerParser.choices(in: ["Q?", "  1. A", "❯ 2. B", "  3. C"])
        #expect(AnswerParser.steps(to: c[0], in: c) == -1)
        #expect(AnswerParser.steps(to: c[2], in: c) == 1)
        #expect(AnswerParser.steps(to: c[1], in: c) == 0)
    }
}

struct AntigravityApprovalTests {
    // Antigravity CLI 1.5.2's command approval on a phone-width terminal (options wrap).
    let screen = [
        "Command",
        "────────────────────────────────────────",
        "",
        "Requesting permission for:",
        "   ls -la /home/me/project",
        "",
        "Run this command?",
        "> 1. Yes, run command",
        "  2. Yes, and always allow in this conversation for",
        "commands that start with 'ls'",
        "  3. Yes, and always allow for commands that start",
        "with 'ls' (Persist to settings.json)",
        "  4. No, cancel",
        "",
        "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand comma",
        "esc to cancel  accept-edits · Gemini 4 Argon · medium",
    ]

    @Test func wrappedOptionsJoin() {
        let choices = AnswerParser.choices(in: screen)
        #expect(choices.map(\.number) == [1, 2, 3, 4])
        #expect(choices[1].label == "Yes, and always allow in this conversation for commands that start with 'ls'")
        #expect(choices[2].label == "Yes, and always allow for commands that start with 'ls' (Persist to settings.json)")
        #expect(choices[0].selected)
    }

    @Test func questionAndContext() {
        #expect(AnswerParser.question(in: screen) == "Run this command?")
        #expect(AnswerParser.context(in: screen) == ["Requesting permission for:", "ls -la /home/me/project"])
    }
}
