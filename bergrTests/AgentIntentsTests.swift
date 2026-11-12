import Foundation
import Testing
@testable import bergr

struct AgentIntentsTests {
    typealias Row = BergrActivityAttributes.Row

    func row(_ title: String, _ status: String, needsYou: Bool, machine: String = "box", address: String) -> Row {
        Row(kind: "claude", title: title, status: status, machine: machine, needsYou: needsYou,
            host: "11111111-2222-3333-4444-555555555555", address: address)
    }

    /// Writer order: needs-you first, then working, then done (as the app writes it).
    var fixture: AgentsSnapshot {
        AgentsSnapshot(
            needsYou: 2, working: 1, done: 1,
            rows: [
                row("Refactor", "Needs approval", needsYou: true, machine: "pop-os", address: "t1"),
                row("Tests", "Waiting", needsYou: true, machine: "box", address: "t2"),
                row("Docs", "Working", needsYou: false, address: "t3"),
            ],
            updated: .now)
    }

    @Test func sortingPutsNeedsYouFirstAndKeepsTheRest() {
        let rows = [
            row("Done one", "Ready", needsYou: false, address: "t9"),
            row("Working", "Working", needsYou: false, address: "t3"),
            row("Blocked", "Needs you", needsYou: true, address: "t1"),
        ]
        #expect(AgentCatalog.sorted(rows).map(\.address) == ["t1", "t9", "t3"])
    }

    @Test func matchingIsCaseInsensitiveAndChecksMachineAndStatus() {
        let rows = fixture.rows
        #expect(AgentCatalog.matching("refactor", in: rows).map(\.address) == ["t1"])
        #expect(AgentCatalog.matching("POP-OS", in: rows).map(\.address) == ["t1"])
        #expect(AgentCatalog.matching("waiting", in: rows).map(\.address) == ["t2"])
        #expect(AgentCatalog.matching("  ", in: rows).count == 3)
        #expect(AgentCatalog.matching("nothing like this", in: rows).isEmpty)
    }

    @Test func needingYouListsOnlyBlockedRowsFirst() {
        #expect(AgentCatalog.needingYou(fixture).map(\.address) == ["t1", "t2"])
    }

    @Test func whatNeedsMeNamesEachAgentAndMachine() {
        #expect(AgentCatalog.needsYouText(fixture)
            == "2 agents need you: Refactor on pop-os, Tests on box.")
    }

    @Test func whatNeedsMeCountsAgentsTheSnapshotDoesNotList() {
        let snapshot = AgentsSnapshot(
            needsYou: 5, working: 0, done: 0,
            rows: [row("A", "Needs you", needsYou: true, address: "t1")], updated: .now)
        #expect(AgentCatalog.needsYouText(snapshot) == "5 agents need you: A on box, and 4 more.")
    }

    @Test func whatNeedsMeWithNobodyBlocked() {
        let working = AgentsSnapshot(needsYou: 0, working: 2, done: 0, rows: [], updated: .now)
        #expect(AgentCatalog.needsYouText(working) == "Nothing needs you. 2 working.")
        #expect(AgentCatalog.needsYouText(.empty) == "Nothing needs you.")
    }

    @Test func singularNeedsYou() {
        let one = AgentsSnapshot(
            needsYou: 1, working: 0, done: 0, rows: [row("A", "Needs you", needsYou: true, address: "t1")], updated: .now)
        #expect(AgentCatalog.needsYouText(one) == "1 agent needs you: A on box.")
    }

    @Test func entityIdentifiesTheTerminalAndKeepsItsAddress() {
        let entity = AgentEntity(row: row("Docs", "Working", needsYou: false, address: "t3"))
        #expect(entity.id == "11111111-2222-3333-4444-555555555555|t3")
        #expect(entity.address == "t3")
        #expect(entity.host == "11111111-2222-3333-4444-555555555555")
    }

    @Test func widgetRowsForActiveAgentsOnly() {
        // Two needing you and one working: the Lock Screen's two rows are the two blocked agents.
        #expect(AgentWidgetContent.activeRows(fixture, limit: 2).map(\.address) == ["t1", "t2"])
        // One needing you, nothing working: the done row is not shown.
        let snapshot = AgentsSnapshot(
            needsYou: 1, working: 0, done: 1,
            rows: [
                row("A", "Needs you", needsYou: true, address: "t1"),
                row("Ready", "Ready", needsYou: false, address: "t2"),
            ], updated: .now)
        #expect(AgentWidgetContent.activeRows(snapshot, limit: 2).map(\.address) == ["t1"])
        #expect(AgentWidgetContent.activeRows(.empty, limit: 2).isEmpty)
    }

    @Test func inlineWidgetText() {
        #expect(AgentWidgetContent.inlineText(fixture) == "2 need you · 1 working")
        #expect(AgentWidgetContent.inlineText(AgentsSnapshot(needsYou: 1, working: 0, done: 0, rows: [], updated: .now))
            == "1 needs you")
        #expect(AgentWidgetContent.inlineText(.empty) == "Nothing needs you")
    }

    @Test func queueKeepsOrderAndEmptiesOnTake() throws {
        let store = try #require(UserDefaults(suiteName: "bergr.tests.intents.\(UUID().uuidString)"))
        IntentQueue.enqueue(.openNeedsYou, in: store)
        IntentQueue.enqueue(.message(host: "h", address: "t1", text: "yes"), in: store)
        #expect(IntentQueue.take(from: store) == [.openNeedsYou, .message(host: "h", address: "t1", text: "yes")])
        #expect(IntentQueue.take(from: store).isEmpty)
    }

    @Test func startSessionBecomesAPrefillForAKnownAgentOnly() {
        let known = NewSessionPrefill(.newSession(machine: "pop-os", agent: "codex", folder: "~/src/app", message: "hi"))
        #expect(known == NewSessionPrefill(machine: "pop-os", agent: .codex, folder: "~/src/app", message: "hi"))
        #expect(NewSessionPrefill(.newSession(machine: "pop-os", agent: "gemini", folder: "", message: "")) == nil)
        #expect(NewSessionPrefill(.openNeedsYou) == nil)
    }
}
