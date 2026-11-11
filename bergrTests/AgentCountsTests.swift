import Foundation
import HerdrKit
import Testing
@testable import bergr

struct AgentCountsTests {
    func terminal(_ address: String, _ state: String, lifecycle: String = "live") throws -> Terminal {
        let json = """
        {"address":"\(address)","name":"\(address)","state":"\(lifecycle)","turn":1,"labels":{},
         "status":{"state":"\(state)"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func emptyIsZero() {
        #expect(AgentCounts(terminals: []) == AgentCounts())
    }

    @Test func countsByState() throws {
        let counts = AgentCounts(terminals: [
            try terminal("t1", "blocked"), try terminal("t2", "blocked"),
            try terminal("t3", "working"), try terminal("t4", "done"), try terminal("t5", "idle"),
        ])
        #expect(counts.needsYou == 2)
        #expect(counts.working == 1)
        #expect(counts.done == 1)
    }

    @Test func finishedTerminalsDoNotCount() throws {
        let counts = AgentCounts(terminals: [try terminal("t1", "blocked", lifecycle: "finished")])
        #expect(counts == AgentCounts())
    }

    @Test func agentRefRoundTrips() throws {
        let ref = AgentRef(host: UUID(), address: "t7")
        let back = try JSONDecoder().decode(AgentRef.self, from: JSONEncoder().encode(ref))
        #expect(back == ref)
    }
}
