import Foundation
import HerdrKit
import Testing
@testable import bergr

struct LiveActivityTests {
    let host = UUID()

    func terminal(_ address: String, _ state: String, name: String? = nil, msg: String? = nil, lifecycle: String = "live") throws -> Terminal {
        let msgJSON = msg.map { ",\"msg\":\"\($0)\"" } ?? ""
        let json = """
        {"address":"\(address)","name":"\(name ?? address)","state":"\(lifecycle)","turn":1,"labels":{},
         "status":{"state":"\(state)"\(msgJSON)}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    func machine(_ terminals: [Terminal], name: String = "box") -> LiveActivityMachine {
        LiveActivityMachine(host: host, name: name, terminals: terminals)
    }

    @Test func emptyHasNoActivity() throws {
        #expect(LiveActivityController.content(machines: []) == nil)
        #expect(LiveActivityController.content(machines: [machine([])]) == nil)
        #expect(LiveActivityController.content(machines: [machine([try terminal("t1", "idle", lifecycle: "finished")])]) == nil)
    }

    @Test func countsAndOrdering() throws {
        let m = machine([
            try terminal("t1", "working"),
            try terminal("t2", "blocked", msg: "Run rm?"),
            try terminal("t3", "done"),
            try terminal("t4", "working"),
        ])
        let content = try #require(LiveActivityController.content(machines: [m]))
        #expect(content.needsYou == 1)
        #expect(content.working == 2)
        #expect(content.done == 1)
        #expect(content.rows.map(\.address) == ["t2", "t1", "t4"])
        #expect(content.rows[0].needsYou)
        #expect(content.rows[0].status == "Run rm?")
        #expect(content.rows[1].status == "Working")
        #expect(content.rows[0].machine == "box")
    }

    @Test func atMostThreeRows() throws {
        let m = machine(try (1...5).map { try terminal("t\($0)", $0 > 3 ? "blocked" : "working") })
        let content = try #require(LiveActivityController.content(machines: [m]))
        #expect(content.rows.count == 3)
        #expect(content.rows.map(\.address) == ["t4", "t5", "t1"])
        #expect(content.needsYou == 2)
        #expect(content.working == 3)
    }

    @Test func onlyDoneStillShows() throws {
        let content = try #require(LiveActivityController.content(machines: [machine([try terminal("t1", "done")])]))
        #expect(content.done == 1)
        #expect(content.rows.map(\.address) == ["t1"])
    }

    @Test func deepLinkRoundTrip() throws {
        let content = try #require(LiveActivityController.content(machines: [machine([try terminal("t7", "blocked")])]))
        let target = try #require(LiveActivityController.target(of: content.rows[0].url))
        #expect(target.host == host)
        #expect(target.address == "t7")
        #expect(LiveActivityController.target(of: URL(string: "https://example.com")!) == nil)
    }
}
