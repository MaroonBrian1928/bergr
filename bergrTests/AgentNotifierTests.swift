import Foundation
import HerdrKit
import Testing
import UserNotifications
@testable import bergr

struct AgentNotifierTests {
    let host = UUID()

    func terminal(_ state: String, turn: Int = 1, ms: Int = 100, seen: Int? = nil, title: String? = nil) throws -> Terminal {
        let labels = seen.map { "{\"herdr.seen\":\"\($0)\"}" } ?? "{}"
        let titleJSON = title.map { ",\"title\":\"\($0)\"" } ?? ""
        let json = """
        {"address":"t1","name":"api","state":"live","turn":\(turn),"status_ms":\(ms),"labels":\(labels),
         "status":{"state":"\(state)"\(titleJSON)}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func blockedNeedsYou() throws {
        let alerts = AgentNotifier.alerts(host: host, old: [try terminal("working")], new: [try terminal("blocked", title: "Run rm?")])
        #expect(alerts.count == 1)
        #expect(alerts[0].title == "api needs you")
        #expect(alerts[0].body == "Run rm?")
    }

    @Test func doneFinished() throws {
        let alerts = AgentNotifier.alerts(host: host, old: [try terminal("working", turn: 1)], new: [try terminal("done", turn: 2, seen: 1)])
        #expect(alerts.map(\.title) == ["api is done"])
    }

    @Test func noAlertWhenUnchangedFocusedOrRepeated() throws {
        let working = try terminal("working")
        let blocked = try terminal("blocked")
        #expect(AgentNotifier.alerts(host: host, old: [blocked], new: [blocked]).isEmpty)
        #expect(AgentNotifier.alerts(host: host, old: [working], new: [blocked], focused: "t1").isEmpty)
        let first = AgentNotifier.alerts(host: host, old: [working], new: [blocked])
        let again = AgentNotifier.alerts(host: host, old: [working], new: [blocked], delivered: Set(first.map(\.key)))
        #expect(again.isEmpty)
    }

    @Test func workingToIdleAndSeenDoneAreQuiet() throws {
        #expect(AgentNotifier.alerts(host: host, old: [try terminal("working")], new: [try terminal("idle")]).isEmpty)
        #expect(AgentNotifier.alerts(host: host, old: [try terminal("working")], new: [try terminal("done", turn: 2, seen: 2)]).isEmpty)
    }

    @Test func doneBeforeTheTurnGoesUpStillAlerts() throws {
        // "done" arrives with the old turn (already seen), then the turn goes up: unread now.
        let early = try terminal("done", turn: 1, seen: 1)
        #expect(AgentNotifier.alerts(host: host, old: [try terminal("working", turn: 1, seen: 1)], new: [early]).isEmpty)
        let alerts = AgentNotifier.alerts(host: host, old: [early], new: [try terminal("done", turn: 2, seen: 1)])
        #expect(alerts.map(\.title) == ["api is done"])
    }

    @Test func errorAlertsOnceAndNamesTheMachine() throws {
        let old = [try terminal("working")], new = [try terminal("error", ms: 200)]
        let alerts = AgentNotifier.alerts(host: host, old: old, new: new, machine: "pop")
        #expect(alerts.map(\.title) == ["api hit an error on pop"])
        #expect(alerts[0].kind == .error)
        #expect(alerts[0].kind.interruptionLevel == .timeSensitive)
        #expect(AgentNotifier.Kind.finished.interruptionLevel == .passive)
        #expect(AgentNotifier.alerts(host: host, old: old, new: new, delivered: Set(alerts.map(\.key))).isEmpty)
    }
}
