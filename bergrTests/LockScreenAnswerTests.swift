import Foundation
import HerdrKit
import Testing
@testable import bergr

struct LockScreenAnswerTests {
    let host = UUID()

    func terminal(_ address: String, _ state: String, title: String? = nil) throws -> Terminal {
        let titleJSON = title.map { ",\"title\":\"\($0)\"" } ?? ""
        let json = """
        {"address":"\(address)","name":"\(address)","state":"live","turn":1,"labels":{},
         "status":{"state":"\(state)"\(titleJSON)}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    func machine(_ terminals: [Terminal]) -> LiveActivityMachine {
        LiveActivityMachine(host: host, name: "box", terminals: terminals)
    }

    let numbered = [
        "Edit file?", "", "❯ 1. Yes", "  2. Yes, and don't ask again", "  3. No", "",
    ]
    let freeText = ["Overwrite config? (y/n)", ""]

    func key(_ t: Terminal) -> String { LiveActivityController.screenKey(host: host, terminal: t) }

    @Test func numberedChoicesFromScreen() throws {
        let t = try terminal("t1", "blocked", title: "Needs approval")
        let state = try #require(LiveActivityController.content(machines: [machine([t])], screens: [key(t): numbered]))
        let prompt = try #require(state.prompt)
        #expect(prompt.question == "Edit file?")
        #expect(prompt.options.map(\.label) == ["Yes", "Yes, and don't ask again", "No"])
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.address == "t1")
    }

    @Test func fallbackYesNoEsc() throws {
        let t = try terminal("t1", "blocked", title: "Needs approval")
        let state = try #require(LiveActivityController.content(machines: [machine([t])], screens: [key(t): freeText]))
        let prompt = try #require(state.prompt)
        #expect(prompt.question == "Overwrite config? (y/n)")
        #expect(prompt.options.map(\.key) == ["y", "n", "esc"])
    }

    @Test func atMostFourChoices() {
        let lines = ["Pick one?"] + (1...6).map { "  \($0). Option \($0)" }
        #expect(PromptReading.read(lines: lines, statusTitle: nil).options.count == 4)
    }

    @Test func numberedPromptBeatsFallbackAndNoScreenMeansNoPrompt() throws {
        let a = try terminal("t1", "blocked")
        let b = try terminal("t2", "blocked")
        let c = try terminal("t3", "blocked")
        let screens = [key(a): freeText, key(b): numbered]
        let state = try #require(LiveActivityController.content(machines: [machine([c, a, b])], screens: screens))
        #expect(state.prompt?.address == "t2")
        #expect(LiveActivityController.content(machines: [machine([c])], screens: [:])?.prompt == nil)
        let working = try terminal("t4", "working")
        #expect(LiveActivityController.content(machines: [machine([working])], screens: [key(working): numbered])?.prompt == nil)
    }

    @Test func samePromptSendsArrowsAndEnter() {
        let decision = AnswerPolicy.decide(
            question: "Edit file?", number: 3, label: "No", key: "", lines: numbered, statusTitle: nil)
        #expect(decision == .send(steps: [.down, .down, .enter], question: "Edit file?", answer: "No"))
    }

    @Test func changedPromptSendsNothing() {
        let other = ["Delete file?", "", "❯ 1. Yes", "  2. No"]
        #expect(AnswerPolicy.decide(question: "Edit file?", number: 1, label: "Yes", key: "", lines: other, statusTitle: nil) == .changed)
        // Same question, different label at that number.
        let relabeled = ["Edit file?", "", "❯ 1. Yes", "  2. Maybe"]
        #expect(AnswerPolicy.decide(question: "Edit file?", number: 2, label: "No", key: "", lines: relabeled, statusTitle: nil) == .changed)
        // A prompt that went away.
        #expect(AnswerPolicy.decide(question: "Edit file?", number: 1, label: "Yes", key: "", lines: ["$ "], statusTitle: nil) == .changed)
    }

    @Test func fallbackKeysOnlyAnswerTheSameFreeTextQuestion() {
        let q = "Overwrite config? (y/n)"
        #expect(AnswerPolicy.decide(question: q, number: 0, label: "Yes", key: "y", lines: freeText, statusTitle: nil)
            == .send(steps: [.text("y")], question: q, answer: "Yes"))
        #expect(AnswerPolicy.decide(question: q, number: 0, label: "Esc", key: "esc", lines: freeText, statusTitle: nil)
            == .send(steps: [.escape], question: q, answer: "Canceled (esc)"))
        #expect(AnswerPolicy.decide(question: q, number: 0, label: "Yes", key: "y", lines: ["Delete it? (y/n)"], statusTitle: nil) == .changed)
        // Numbered choices appeared: never type y into them.
        #expect(AnswerPolicy.decide(question: q, number: 0, label: "Yes", key: "y", lines: numbered, statusTitle: nil) == .changed)
    }

    @Test func snapshotCountsFollowContent() throws {
        let t = try terminal("t1", "blocked")
        let state = LiveActivityController.content(machines: [machine([t])])
        let snapshot = AgentsSnapshot(state)
        #expect(snapshot.needsYou == 1 && snapshot.rows.count == 1)
    }

    /// Claude signed out: herdr-core says blocked, but nothing is asked. No Yes/No buttons
    /// (they'd type "n" into its input), and an old button is refused.
    @Test func signedOutOffersNothing() {
        let lines = ["● Login expired · Please run /login", "❯ ", "Not logged in · Run /login"]
        let reading = PromptReading.read(lines: lines, statusTitle: "Claude")
        #expect(reading.options.isEmpty)
        #expect(AnswerPolicy.decide(question: "Claude", number: 0, label: "No", key: "n",
                                    lines: lines, statusTitle: "Claude") == .changed)
    }

    @Test func loginStepsFromScreen() {
        let paste = ["Browse to: https://claude.ai/oauth/authorize?code=true&client_id=abc",
                     "&state=xyz123", "", "Paste code here if prompted > "]
        #expect(AnswerParser.loginStep(in: paste)
                == .pasteCode(url: URL(string: "https://claude.ai/oauth/authorize?code=true&client_id=abc&state=xyz123")))
        #expect(AnswerParser.loginStep(in: ["Login successful. Press Enter to continue…"]) == .succeeded)
        #expect(AnswerParser.loginStep(in: ["❯ hello"]) == nil)
        #expect(!AnswerParser.isAsking(paste), "no Yes/No bar over the code prompt")
    }

    @Test func rewindMenuIsSeen() {
        let lines = ["▔▔▔▔", "   Rewind", "", "   Failed to summarize:", "   Login expired · Please run /login", "", "   Esc to cancel"]
        #expect(AnswerParser.rewindOpen(lines))
        #expect(!AnswerParser.isAsking(lines))
        #expect(!AnswerParser.rewindOpen(["❯ Rewind the db"]))
    }

    @Test func loginSuccessHigherUpIsOver() {
        let lines = ["Login successful. Press Enter to continue…", "", "● I'm here.", "a", "b", "c", "d", "e", "────", "❯ ", "────"]
        #expect(AnswerParser.loginStep(in: lines) == nil)
    }
}
