import Foundation
import HerdrKit
import Testing
@testable import bergr

struct AgentsListPerfTests {
    private func terminal(_ address: String, state: String, minutesAgo: Double, now: Date) throws -> Terminal {
        let ms = UInt64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000)
        let json = """
        {"address":"\(address)","name":"\(address)","state":"live","turn":1,"labels":{},"created_ms":\(ms),"status_ms":\(ms),
         "status":{"state":"\(state)","app":"claude-code"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func explicitSecondsGiveTheSameAnswersAsTheSetting() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        try QuietAgentsSetting.with {
            let cases: [(state: String, minutesAgo: Double)] = [
                ("done", 30), ("done", 25 * 60), ("idle", 9 * 1440), ("blocked", 9 * 1440), ("working", 9 * 1440),
            ]
            for seconds in [0, 3600, 86400] {
                UserDefaults.standard.set(seconds, forKey: QuietAgents.key)
                #expect(QuietAgents.seconds == seconds)
                for (state, minutes) in cases {
                    let t = try terminal("t1", state: state, minutesAgo: minutes, now: now)
                    #expect(QuietAgents.isQuiet(t, now: now) == QuietAgents.isQuiet(t, now: now, after: seconds))
                }
            }
        }
    }

    @Test func heartbeatsChangeNothing() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let current = TerminalSnapshot(seq: 5, terminals: [try terminal("t1", state: "working", minutesAgo: 1, now: now)])
        #expect(HostSession.snapshot(after: .heartbeat(seq: 6), from: current) == nil)
    }

    @Test func missedSnapshotReplacesTheSnapshotAndItsSeq() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let t1 = try terminal("t1", state: "working", minutesAgo: 1, now: now)
        let current = TerminalSnapshot(seq: 5, terminals: [t1])
        // Same terminals: still written, so the seq follows the core's.
        let same = HostSession.snapshot(after: .missed(seq: 9, terminals: [t1]), from: current)
        #expect(same?.seq == 9)
        #expect(same?.terminals == [t1])
        let emptied = HostSession.snapshot(after: .missed(seq: 10, terminals: []), from: current)
        #expect(emptied?.terminals.isEmpty == true)
    }
}
