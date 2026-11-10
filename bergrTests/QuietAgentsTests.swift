import Foundation
import HerdrKit
import Testing
@testable import bergr

struct QuietAgentsTests {
    func terminal(_ state: String, minutesAgo: Double, now: Date) throws -> Terminal {
        let ms = UInt64((now.timeIntervalSince1970 - minutesAgo * 60) * 1000)
        let json = """
        {"address":"t1","name":"t1","state":"live","turn":1,"labels":{},"created_ms":\(ms),"status_ms":\(ms),
         "status":{"state":"\(state)","app":"claude-code"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func finishedAgentsUntouchedForLongerAreQuiet() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(QuietAgents.isQuiet(try terminal("done", minutesAgo: 25 * 60, now: now), now: now, after: 86400))
        #expect(!QuietAgents.isQuiet(try terminal("done", minutesAgo: 30, now: now), now: now, after: 86400))
        // Needing you or working always counts, however long ago it started.
        #expect(!QuietAgents.isQuiet(try terminal("blocked", minutesAgo: 9 * 1440, now: now), now: now, after: 86400))
        #expect(!QuietAgents.isQuiet(try terminal("working", minutesAgo: 9 * 1440, now: now), now: now, after: 86400))
        // Never.
        #expect(!QuietAgents.isQuiet(try terminal("done", minutesAgo: 9 * 1440, now: now), now: now, after: 0))
    }
}
