import Foundation
import Testing
@testable import bergr

struct NotificationPrefsTests {
    let host = UUID()

    private func allows(_ p: NotificationPrefs, _ kind: AgentNotifier.Kind, _ address: String = "t1", at minute: Int = 12 * 60) -> Bool {
        p.allows(kind: kind, host: host, address: address, minute: minute)
    }

    @Test func defaultsChangeNothing() {
        let p = NotificationPrefs()
        for kind in [AgentNotifier.Kind.needsYou, .finished, .error] {
            #expect(allows(p, kind, at: 3 * 60))
        }
    }

    @Test func kindSwitches() {
        var p = NotificationPrefs()
        p.finished = false
        #expect(!allows(p, .finished))
        #expect(allows(p, .needsYou))
        #expect(allows(p, .error))
        p.needsYou = false
        #expect(!allows(p, .needsYou))
        p.errors = false
        #expect(!allows(p, .error))
    }

    @Test func mutedAgentIsKeyedByMachineAndAddress() {
        var p = NotificationPrefs()
        p.setMuted(true, host: host, address: "t1", name: "Claude")
        #expect(!allows(p, .needsYou, "t1"))
        #expect(allows(p, .needsYou, "t2"))
        #expect(p.allows(kind: .needsYou, host: UUID(), address: "t1", minute: 0))
        p.setMuted(false, host: host, address: "t1", name: "Claude")
        #expect(allows(p, .needsYou, "t1"))
    }

    @Test func quietHoursKeepOnlyNeedsYou() {
        var p = NotificationPrefs()
        p.quietEnabled = true
        p.quietStart = 12 * 60
        p.quietEnd = 14 * 60
        #expect(!allows(p, .finished, at: 13 * 60))
        #expect(!allows(p, .error, at: 12 * 60))
        #expect(allows(p, .needsYou, at: 13 * 60))
        #expect(allows(p, .finished, at: 14 * 60))
        #expect(allows(p, .finished, at: 11 * 60 + 59))
    }

    @Test func quietHoursCrossingMidnight() {
        var p = NotificationPrefs()
        p.quietEnabled = true // 22:00 to 07:00
        #expect(!allows(p, .finished, at: 23 * 60))
        #expect(!allows(p, .finished, at: 0))
        #expect(!allows(p, .finished, at: 6 * 60 + 59))
        #expect(allows(p, .finished, at: 7 * 60))
        #expect(allows(p, .finished, at: 12 * 60))
        #expect(allows(p, .finished, at: 21 * 60 + 59))
        #expect(!allows(p, .finished, at: 22 * 60))
        #expect(allows(p, .needsYou, at: 23 * 60))
    }

    @Test func quietOffMeansNever() {
        var p = NotificationPrefs()
        p.quietEnabled = false
        #expect(allows(p, .finished, at: 23 * 60))
    }

    @Test func minuteUsesTheGivenZone() {
        let noonUTC = Date(timeIntervalSince1970: 1_704_110_400)
        #expect(NotificationPrefs.minute(of: noonUTC, in: TimeZone(secondsFromGMT: 0)!) == 12 * 60)
        #expect(NotificationPrefs.minute(of: noonUTC, in: TimeZone(secondsFromGMT: -5 * 3600)!) == 7 * 60)
    }

    @Test func storageRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "notifprefs-\(UUID())"))
        #expect(NotificationPrefs.load(defaults) == NotificationPrefs())
        var p = NotificationPrefs()
        p.finished = false
        p.setMuted(true, host: host, address: "t1", name: "Claude")
        p.save(defaults)
        #expect(NotificationPrefs.load(defaults) == p)
    }

    @Test func registrationCarriesPrefsForThatMachineOnly() throws {
        var p = NotificationPrefs()
        p.finished = false
        p.quietEnabled = true
        p.setMuted(true, host: host, address: "t1", name: "Claude")
        p.setMuted(true, host: UUID(), address: "other", name: "Elsewhere")
        let data = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "p", key: nil, host: host, prefs: p)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let device = try #require(object["device"] as? [String: Any])
        let prefs = try #require(device["prefs"] as? [String: Any])
        #expect(prefs["kinds"] as? [String: Bool] == ["needs_you": true, "finished": false, "error": true])
        #expect(prefs["muted"] as? [String] == ["t1"])
        #expect(prefs["quiet"] as? [String: Int] == ["start": 22 * 60, "end": 7 * 60])
        #expect(prefs["tz"] as? String == TimeZone.current.identifier)
        #expect(prefs["tz_offset"] is Int)
    }

    @Test func registrationWithoutPrefsHasNoField() throws {
        let data = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "p", key: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let device = try #require(object["device"] as? [String: Any])
        #expect(device["prefs"] == nil)
    }

    @Test func quietIsOmittedWhenOff() throws {
        let payload = NotificationPrefs().payload(host: host)
        #expect(payload["quiet"] == nil)
    }
}
