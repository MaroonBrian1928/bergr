import Foundation
import HerdrKit
import Testing
@testable import bergr

@MainActor
struct MacNotificationTests {
    @Test func macOSNeverWantsTheHelper() {
        for stay in [false, true] {
            for notifications in [false, true] {
                for lock in [false, true] {
                    #expect(!Delivery.helperWanted(stayRunning: stay, notifications: notifications, lockScreen: lock,
                                                   helperSupported: false))
                }
            }
        }
    }

    @Test func iOSHelperRuleIsUnchangedWhenSupported() {
        #expect(Delivery.helperWanted(stayRunning: false, notifications: true, lockScreen: false, helperSupported: true))
        #expect(!Delivery.helperWanted(stayRunning: true, notifications: true, lockScreen: true, helperSupported: true))
    }

    @Test func helperSupportFollowsThePlatform() {
        #if os(iOS)
        #expect(Delivery.helperSupported)
        #else
        #expect(!Delivery.helperSupported)
        #endif
    }

    @Test func clickRouteMatchesTheAgentRefTheWindowOpens() throws {
        let host = UUID()
        let terminal = try JSONDecoder().decode(Terminal.self, from: Data("""
        {"address":"t9","name":"api","state":"live","turn":1,"status_ms":5,"labels":{},
         "status":{"state":"blocked"}}
        """.utf8))
        let alerts = AgentNotifier.alerts(host: host, old: [], new: [terminal])
        #expect(alerts.isEmpty)  // first look is not a transition
        let working = try JSONDecoder().decode(Terminal.self, from: Data("""
        {"address":"t9","name":"api","state":"live","turn":1,"status_ms":1,"labels":{},
         "status":{"state":"working"}}
        """.utf8))
        let needsYou = AgentNotifier.alerts(host: host, old: [working], new: [terminal])
        let alert = try #require(needsYou.first)
        let target = try #require(NotificationDelegate.target(["host": host.uuidString, "address": alert.address]))
        #expect(AgentRef(host: target.host, address: target.address) == AgentRef(host: host, address: "t9"))
    }
}
