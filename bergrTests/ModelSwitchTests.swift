import Testing
@testable import bergr

struct ModelSwitchTests {
    // Antigravity CLI 1.5.2's status line and /model screen, as captured on a real machine.
    let agyScreen = [
        "> /model",
        "  ⎿  Model set to Gemini 4 Argon (Medium)",
        "? for shortcuts                                accept-edits · Gemini 4 Argon · medium",
    ]

    @Test func readsAntigravityStatusLine() throws {
        let status = try #require(AntigravityStatus.read(agyScreen))
        #expect(status.model == "Gemini 4 Argon")
        #expect(status.effort == "medium")
    }

    @Test func ignoresLinesWithoutAModel() {
        #expect(AntigravityStatus.read(["a · b", "nothing here"]) == nil)
    }

    // Codex's "Select Model and Effort" list parses as numbered choices with the current one selected.
    @Test func codexPickerParses() {
        let lines = [
            "  Select Model and Effort",
            "› 1. GPT-6.1-Sol (current)  Latest workhorse model for coding and everyday work.",
            "  2. GPT-6-Astra            Frontier intelligence for the most demanding work.",
            "  3. GPT-6.1 Terra          GPT-6.1 Terra Codex model.",
            "  4. GPT-6-Sol              Previous generation workhorse model.",
            "  enter select · esc back",
        ]
        let choices = AnswerParser.choices(in: lines)
        #expect(choices.count == 4)
        #expect(choices.first?.selected == true)
        let sol = choices.first { $0.label.lowercased().hasPrefix("gpt-6-sol ") }
        #expect(sol?.number == 4)
        #expect(AnswerParser.steps(to: sol!, in: choices) == 3)
    }

    @Test func effortNames() {
        #expect(EffortName.display("xhigh") == "Extra high")
        #expect(EffortName.display("medium") == "Medium")
    }
}

@MainActor
struct PermissionModeTests {
    // Status lines captured from each agent on a real machine.
    @Test func claude() {
        #expect(PermissionModes.current(.claude, in: ["  ⏵⏵ auto mode on (shift+tab to cycle) · install gh"]) == "Auto")
        #expect(PermissionModes.current(.claude, in: ["  ⏸ manual mode on · install gh for PR status"]) == "Manual")
        #expect(PermissionModes.current(.claude, in: ["  ⏵⏵ accept edits on (shift+tab to cycle)"]) == "Accept edits")
        #expect(PermissionModes.current(.claude, in: ["  ⏸ plan mode on (shift+tab to cycle)"]) == "Plan")
    }

    @Test func codex() {
        let line = "  GPT-6.1-Sol medium · /tmp · Approve for me · 5h 100% left · weekly 95% left"
        #expect(PermissionModes.current(.codex, in: [line]) == "Approve for me")
    }

    @Test func antigravity() {
        #expect(PermissionModes.current(.antigravity, in: ["? for shortcuts      accept-edits · Gemini 4 Argon · medium"]) == "Accept edits")
        #expect(PermissionModes.current(.antigravity, in: ["? for shortcuts          plan · Gemini 4 Argon · medium"]) == "Plan")
        #expect(PermissionModes.current(.antigravity, in: ["? for shortcuts               Gemini 4 Argon · medium"]) == "Default")
    }
}
