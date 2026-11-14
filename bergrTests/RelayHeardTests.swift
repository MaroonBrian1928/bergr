import Foundation
import Testing
@testable import bergr

@Suite struct RelayHeardTests {
    @Test func agoText() {
        #expect(RelayHeard.agoText(20) == "just now")
        #expect(RelayHeard.agoText(7 * 60 + 5) == "7 min ago")
        #expect(RelayHeard.agoText(2 * 3600 + 100) == "2h ago")
        #expect(RelayHeard.agoText(3 * 86400) == "3d ago")
    }

    @Test func lastHeardText() {
        #expect(RelayHeard.lastHeardText(2 * 3600) == "Alerts last heard 2h ago")
    }

    @Test func setupRowThreshold() {
        #expect(RelayHeard.alertsState(age: 14 * 60) == .ready("Heard 14 min ago"))
        #expect(RelayHeard.alertsState(age: 15 * 60) == .ready("Heard 15 min ago"))
        if case .warning = RelayHeard.alertsState(age: 15 * 60 + 1) {} else { Issue.record("expected a warning") }
        if case .warning = RelayHeard.alertsState(age: 3 * 3600) {} else { Issue.record("expected a warning") }
    }

    @Test func neverHeardIsNotAFault() {
        if case .ready = RelayHeard.alertsState(age: nil) {} else { Issue.record("expected ready") }
    }

    @Test func parsesTheRelayAnswerWithItsOwnClock() throws {
        let id = UUID()
        let json = #"{"now": 10000000, "machines": [{"id": "\#(id.uuidString)", "at": 9000000, "working": 1}]}"#
        let heard = try #require(RelayHeard.parse(Data(json.utf8)))
        #expect(heard.age(of: id) == 1000)
        #expect(heard.age(of: UUID()) == nil)
        #expect(RelayHeard.parse(Data("{}".utf8)) == nil)
    }
}
