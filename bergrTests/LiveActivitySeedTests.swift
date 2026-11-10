import Foundation
import HerdrKit
import Testing
@testable import bergr

/// The per-machine seed the phone sends with the Live Activity's push token.
@Suite(.serialized)
struct LiveActivitySeedTests {
    func terminal(_ address: String, _ state: String, name: String? = nil, msg: String? = nil,
                  statusMs: UInt64? = nil) throws -> Terminal {
        let msgJSON = msg.map { ",\"msg\":\"\($0)\"" } ?? ""
        let stamp = statusMs.map { ",\"status_ms\":\($0)" } ?? ""
        let json = """
        {"address":"\(address)","name":"\(name ?? address)","state":"live","turn":1,"labels":{}\(stamp),
         "status":{"state":"\(state)"\(msgJSON)}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    func machine(_ name: String, _ terminals: [Terminal]) -> LiveActivityMachine {
        LiveActivityMachine(host: UUID(), name: name, terminals: terminals)
    }

    /// Two machines with a mix of states: nothing hidden (no timestamps, so nothing is old).
    func fleet() throws -> [LiveActivityMachine] {
        [
            machine("box", [
                try terminal("t1", "blocked", msg: "Run rm?"),
                try terminal("t2", "working"),
                try terminal("t3", "done"),
            ]),
            machine("lab", [
                try terminal("t4", "working"),
                try terminal("t5", "working"),
            ]),
        ]
    }

    @Test func perMachineCountsSumToTotals() throws {
        let machines = try fleet()
        let totals = try #require(LiveActivityController.content(machines: machines))
        let seed = LiveActivityController.seed(machines: machines, fullContent: false)
        var needs = 0, working = 0, done = 0
        for entry in seed.values {
            let counts = try #require(entry as? [String: Any])
            needs += try #require(counts["needsYou"] as? Int)
            working += try #require(counts["working"] as? Int)
            done += try #require(counts["done"] as? Int)
        }
        #expect(needs == totals.needsYou)
        #expect(working == totals.working)
        #expect(done == totals.done)
        #expect(totals.needsYou == 1 && totals.working == 3 && totals.done == 1)
    }

    @Test func keysAreHostUUIDStrings() throws {
        let machines = try fleet()
        let seed = LiveActivityController.seed(machines: machines, fullContent: false)
        #expect(Set(seed.keys) == Set(machines.map { $0.host.uuidString }))
        let box = try #require(seed[machines[0].host.uuidString] as? [String: Any])
        #expect(box["needsYou"] as? Int == 1)
        #expect(box["working"] as? Int == 1)
        #expect(box["done"] as? Int == 1)
        let lab = try #require(seed[machines[1].host.uuidString] as? [String: Any])
        #expect(lab["working"] as? Int == 2)
        #expect(lab["needsYou"] as? Int == 0)
    }

    @Test func rowsOnlyInFullMode() throws {
        let machines = try fleet()
        let counts = LiveActivityController.seed(machines: machines, fullContent: false)
        for entry in counts.values {
            let object = try #require(entry as? [String: Any])
            #expect(object["rows"] == nil)
        }

        let full = LiveActivityController.seed(machines: machines, fullContent: true)
        let box = try #require(full[machines[0].host.uuidString] as? [String: Any])
        let rows = try #require(box["rows"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows[0]["address"] as? String == "t1")
        #expect(rows[0]["needsYou"] as? Bool == true)
        #expect(rows[0]["status"] as? String == "Run rm?")
        #expect(rows[0]["machine"] as? String == "box")
        #expect(rows[0]["host"] as? String == machines[0].host.uuidString)
        #expect(rows[0]["kind"] as? String == "shell")
        #expect(Set(rows[0].keys) == ["kind", "title", "status", "machine", "needsYou", "host", "address"])
    }

    @Test func serializesToJSON() throws {
        let seed = LiveActivityController.seed(machines: try fleet(), fullContent: true)
        #expect(JSONSerialization.isValidJSONObject(seed))
        _ = try JSONSerialization.data(withJSONObject: seed)
    }

    @Test func emptyMachinesGiveEmptySeed() {
        #expect(LiveActivityController.seed(machines: [], fullContent: true).isEmpty)
    }

    @Test func hiddenFinishedAgentsAreLeftOut() throws {
        let key = QuietAgents.key
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(3600, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let twoHoursAgo = UInt64((Date.now.timeIntervalSince1970 - 2 * 3600) * 1000)
        let now = UInt64(Date.now.timeIntervalSince1970 * 1000)
        let machines = [
            machine("box", [
                try terminal("old", "done", statusMs: twoHoursAgo),
                try terminal("fresh", "done", statusMs: now),
            ]),
        ]
        let seed = LiveActivityController.seed(machines: machines, fullContent: true)
        let box = try #require(seed[machines[0].host.uuidString] as? [String: Any])
        #expect(box["done"] as? Int == 1)
        let rows = try #require(box["rows"] as? [[String: Any]])
        #expect(rows.map { $0["address"] as? String } == ["fresh"])

        let totals = try #require(LiveActivityController.content(machines: machines))
        #expect(totals.done == 1)
    }
}
