import Foundation
import Testing
@testable import bergr

struct AgentsSnapshotTests {
    @Test func oldSnapshotWithoutNewFieldsDecodes() throws {
        let json = """
        {"needsYou":1,"working":2,"done":0,"rows":[],"updated":0}
        """
        let s = try JSONDecoder().decode(AgentsSnapshot.self, from: Data(json.utf8))
        #expect(s.needsYou == 1 && s.working == 2)
        #expect(s.agents.isEmpty)
        #expect(s.machines.isEmpty)
    }

    @Test func newSnapshotRoundTrips() throws {
        let agent = AgentsSnapshot.Agent(state: "working", name: "api", machine: "box", lastLine: "Running tests.",
                                         host: "H", address: "t1")
        let s = AgentsSnapshot(needsYou: 0, working: 1, done: 0, rows: [], updated: Date(timeIntervalSince1970: 5),
                               agents: [agent], machines: ["H": "box"])
        let back = try JSONDecoder().decode(AgentsSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.agents.first?.lastLine == "Running tests.")
    }

    func agent(_ name: String, _ state: String) -> AgentsSnapshot.Agent {
        .init(state: state, name: name, machine: "m", lastLine: "", host: "h", address: name)
    }

    @Test func mediumRowsAreNeedsYouFirstAndCapped() {
        let s = AgentsSnapshot(needsYou: 1, working: 2, done: 2, rows: [], updated: .now, agents: [
            agent("d1", "done"), agent("w1", "working"), agent("n1", "needsYou"), agent("w2", "working"), agent("d2", "done"),
        ])
        #expect(AgentWidgetContent.mediumAgents(s).map(\.name) == ["n1", "w1", "w2", "d1"])
        #expect(AgentWidgetContent.mediumAgents(s, limit: 2).count == 2)
        #expect(AgentWidgetContent.mediumAgents(.empty).isEmpty)
    }

    @Test func mediumRowsFallBackToRowsForOldSnapshots() {
        let row = BergrActivityAttributes.Row(kind: "claude", title: "api", status: "Working", machine: "box",
                                              needsYou: false, host: "h", address: "t1")
        let s = AgentsSnapshot(needsYou: 0, working: 1, done: 0, rows: [row], updated: .now)
        #expect(AgentWidgetContent.mediumAgents(s).map(\.name) == ["api"])
    }

    @Test func pushThreadAndSummaryArgument() {
        let info: [AnyHashable: Any] = ["host": "H1", "address": "t1"]
        #expect(PushGrouping.result(userInfo: info, machines: ["H1": "studio"])
                == .init(thread: "H1", summaryArgument: "studio"))
        #expect(PushGrouping.result(userInfo: info, machines: [:])?.summaryArgument == "your machines")
        #expect(PushGrouping.result(userInfo: ["address": "t1"], machines: ["H1": "studio"]) == nil)
    }
}
