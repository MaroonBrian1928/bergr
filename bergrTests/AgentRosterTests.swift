import Foundation
import HerdrKit
import Testing
@testable import bergr

struct AgentRosterTests {
    func terminal(_ address: String, _ state: String, lifecycle: String = "live") throws -> Terminal {
        let json = """
        {"address":"\(address)","name":"\(address)","state":"\(lifecycle)","turn":1,"labels":{},
         "status":{"state":"\(state)"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func menuBarTitle() {
        #expect(AgentRoster.menuBarTitle(AgentCounts()) == "")
        #expect(AgentRoster.menuBarTitle(AgentCounts(working: 2)) == "2")
        #expect(AgentRoster.menuBarTitle(AgentCounts(needsYou: 1)) == "1!")
        #expect(AgentRoster.menuBarTitle(AgentCounts(needsYou: 1, working: 2, done: 5)) == "2 · 1!")
    }

    @Test func attentionListsNeedsYouFirstAcrossMachines() throws {
        let a = UUID(), b = UUID()
        let entries = AgentRoster.attention([
            .init(id: a, name: "A", terminals: [try terminal("t1", "working"), try terminal("t2", "idle")]),
            .init(id: b, name: "B", terminals: [try terminal("t3", "blocked"), try terminal("t4", "blocked", lifecycle: "finished")]),
        ])
        #expect(entries.map(\.ref) == [AgentRef(host: b, address: "t3"), AgentRef(host: a, address: "t1")])
        #expect(entries.map(\.machine) == ["B", "A"])
    }

    @Test func stepWraps() {
        let h = UUID()
        let list = ["a", "b", "c"].map { AgentRef(host: h, address: $0) }
        #expect(AgentRoster.step(from: list[0], in: list, by: 1) == list[1])
        #expect(AgentRoster.step(from: list[2], in: list, by: 1) == list[0])
        #expect(AgentRoster.step(from: list[0], in: list, by: -1) == list[2])
        #expect(AgentRoster.step(from: nil, in: list, by: 1) == list[0])
        #expect(AgentRoster.step(from: nil, in: list, by: -1) == list[2])
        #expect(AgentRoster.step(from: AgentRef(host: h, address: "z"), in: list, by: 1) == list[0])
        #expect(AgentRoster.step(from: nil, in: [], by: 1) == nil)
    }
}
