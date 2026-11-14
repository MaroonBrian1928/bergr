import Foundation
import HerdrKit
import Testing
@testable import bergr

struct AppBadgeTests {
    func terminal(_ address: String, _ state: String) throws -> Terminal {
        let json = """
        {"address":"\(address)","name":"\(address)","state":"live","turn":1,"labels":{},"status":{"state":"\(state)"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func badgeCountsNeedsYouAcrossMachines() throws {
        let a = LiveActivityMachine(host: UUID(), name: "a", terminals: [try terminal("t1", "blocked"), try terminal("t2", "working")])
        let b = LiveActivityMachine(host: UUID(), name: "b", terminals: [try terminal("t3", "blocked")])
        let needs = LiveActivityController.needsYouCount(machines: [a, b])
        #expect(needs == 2)
        #expect(AppBadge.count(needsYou: needs, enabled: true) == 2)
    }

    @Test func nothingNeedingYouClears() throws {
        let a = LiveActivityMachine(host: UUID(), name: "a", terminals: [try terminal("t1", "working")])
        #expect(LiveActivityController.needsYouCount(machines: [a]) == 0)
        #expect(LiveActivityController.needsYouCount(machines: []) == 0)
    }

    @Test func settingOffShowsZero() {
        #expect(AppBadge.count(needsYou: 3, enabled: false) == 0)
    }

    @Test func settingDefaultsOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "badge-test-\(UUID().uuidString)"))
        #expect(AppBadge.enabled(defaults))
        defaults.set(false, forKey: AppBadge.key)
        #expect(!AppBadge.enabled(defaults))
    }
}
