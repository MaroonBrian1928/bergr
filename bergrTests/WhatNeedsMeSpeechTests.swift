import Foundation
import Testing
@testable import bergr

/// Records what it was asked and answers with a fixed reply (nil models "can't write").
private actor FakeTextWriter: OnDeviceTextWriting {
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []
    let reply: String?

    init(reply: String?) { self.reply = reply }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        self.instructions.append(instructions)
        prompts.append(prompt)
        return reply
    }
}

@MainActor
struct WhatNeedsMeSpeechTests {
    typealias Row = BergrActivityAttributes.Row

    func row(_ title: String, kind: String = "claude", status: String, machine: String, needsYou: Bool) -> Row {
        Row(kind: kind, title: title, status: status, machine: machine, needsYou: needsYou,
            host: "11111111-2222-3333-4444-555555555555", address: title)
    }

    var fixture: AgentsSnapshot {
        AgentsSnapshot(
            needsYou: 2, working: 1, done: 0,
            rows: [
                row("Migrations", kind: "claude", status: "Needs approval", machine: "pop-os", needsYou: true),
                row("Build", kind: "codex", status: "Error", machine: "raspberrypi", needsYou: true),
                row("Docs", status: "Working", machine: "box", needsYou: false),
            ],
            updated: .now)
    }

    @Test func modelSentenceIsUsedWhenItReturns() async {
        let writer = FakeTextWriter(reply: "Two agents need you: Claude on pop-os is asking to run the migrations.")
        let text = await AgentCatalog.needsYouSpeech(fixture, writer: writer)
        #expect(text == "Two agents need you: Claude on pop-os is asking to run the migrations.")
        #expect(await writer.prompts.count == 1)
    }

    @Test func listTextIsUsedWhenTheModelReturnsNil() async {
        let writer = FakeTextWriter(reply: nil)
        let text = await AgentCatalog.needsYouSpeech(fixture, writer: writer)
        #expect(text == AgentCatalog.needsYouText(fixture))
        #expect(await writer.prompts.count == 1)
    }

    @Test func nothingNeedingYouMakesNoModelCall() async {
        let writer = FakeTextWriter(reply: "should not be used")
        let idle = AgentsSnapshot(needsYou: 0, working: 2, done: 0, rows: [], updated: .now)
        let text = await AgentCatalog.needsYouSpeech(idle, writer: writer)
        #expect(text == "Nothing needs you. 2 working.")
        #expect(await writer.prompts.isEmpty)
    }

    @Test func promptNamesEachRowsAgentMachineAndStatus() async {
        let writer = FakeTextWriter(reply: "ok")
        _ = await AgentCatalog.needsYouSpeech(fixture, writer: writer)
        let prompt = await writer.prompts.first ?? ""
        #expect(prompt.contains("Migrations"))
        #expect(prompt.contains("pop-os"))
        #expect(prompt.contains("Needs approval"))
        #expect(prompt.contains("Build"))
        #expect(prompt.contains("raspberrypi"))
        #expect(prompt.contains("Error"))
        #expect(!prompt.contains("Docs"))
    }

    @Test func unlistedAgentsAreCountedInThePrompt() async {
        let writer = FakeTextWriter(reply: "ok")
        let snapshot = AgentsSnapshot(
            needsYou: 4, working: 0, done: 0,
            rows: [row("A", status: "Waiting", machine: "box", needsYou: true)], updated: .now)
        _ = await AgentCatalog.needsYouSpeech(snapshot, writer: writer)
        #expect(await writer.prompts.first?.contains("Not listed: 3 more.") == true)
    }
}
