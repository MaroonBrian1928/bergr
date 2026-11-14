import Foundation
import Testing
@testable import bergr

struct FocusProfileTests {
    let a = UUID()
    let b = UUID()

    private func kinds(_ p: NotificationPrefs, _ host: UUID?) -> [Bool] {
        let k = p.payload(host: host)["kinds"] as? [String: Bool] ?? [:]
        return [k["needs_you"] ?? true, k["finished"] ?? true, k["error"] ?? true]
    }

    @Test func combineNarrowsKinds() {
        var normal = NotificationPrefs()
        normal.finished = false
        let focus = FocusProfile(needsYou: true, finished: true, errors: false)
        let p = normal.effective(host: a, focus: focus)
        #expect(p.needsYou && !p.finished && !p.errors)
        #expect(normal.effective(host: a, focus: nil) == normal)
    }

    @Test func combineMachines() {
        let normal = NotificationPrefs()
        let focus = FocusProfile(machines: [a])
        #expect(normal.effective(host: a, focus: focus).needsYou)
        let out = normal.effective(host: b, focus: focus)
        #expect(!out.needsYou && !out.finished && !out.errors)
        #expect(!normal.allows(kind: .needsYou, host: b, address: "t", minute: 600, focus: focus))
        #expect(normal.allows(kind: .needsYou, host: a, address: "t", minute: 600, focus: focus))
        #expect(!normal.allows(kind: .finished, host: a, address: "t", minute: 600,
                               focus: FocusProfile(finished: false)))
    }

    @Test func excludedMachineRegistersAllKindsOff() {
        let focus = FocusProfile(machines: [a])
        let prefs = NotificationPrefs().effective(host: b, focus: focus)
        let data = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "p", key: nil, host: b, prefs: prefs)
        let text = String(decoding: data, as: UTF8.self)
        #expect(kinds(prefs, b) == [false, false, false])
        #expect(text.contains("\"needs_you\":false"))
        #expect(kinds(NotificationPrefs().effective(host: a, focus: focus), a) == [true, true, true])
        // The fingerprint changes, so the helper is written again.
        #expect(prefs.fingerprint(host: b) != NotificationPrefs().fingerprint(host: b))
    }

    @Test func clearingRestoresNormal() {
        let suite = UserDefaults(suiteName: "focus-\(UUID().uuidString)")!
        let normal = NotificationPrefs()
        FocusProfile.setActive(FocusProfile(machines: [a], errors: false), suite)
        #expect(normal.effective(host: b, focus: FocusProfile.active(suite)) != normal)
        FocusProfile.setActive(nil, suite)
        #expect(FocusProfile.active(suite) == nil)
        #expect(normal.effective(host: b, focus: FocusProfile.active(suite)) == normal)
        // A profile that changes nothing (what the system sends when a Focus ends) clears too.
        FocusProfile.setActive(FocusProfile(errors: false), suite)
        FocusProfile.setActive(FocusProfile(), suite)
        #expect(FocusProfile.active(suite) == nil)
    }

    @Test func profilePersists() {
        let suite = UserDefaults(suiteName: "focus-\(UUID().uuidString)")!
        let profile = FocusProfile(machines: [a, b], needsYou: true, finished: false, errors: true)
        FocusProfile.setActive(profile, suite)
        #expect(FocusProfile.active(suite) == profile)
    }
}
