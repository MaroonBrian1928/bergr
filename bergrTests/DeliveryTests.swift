import Foundation
import Testing
@testable import bergr

@MainActor
struct DeliveryTests {
    private func defaults(_ values: [String: Bool]) -> UserDefaults {
        let d = UserDefaults(suiteName: "DeliveryTests-\(UUID().uuidString)")!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test func keptConnectedKeepsBoth() {
        let d = defaults([KeepAlive.key: true])
        Delivery.migrate(d)
        #expect(d.bool(forKey: Delivery.notificationsKey))
        #expect(d.bool(forKey: LiveActivityController.pushKey))
    }

    @Test func pushAlertsWithoutLiveActivity() {
        let d = defaults([PushRegistration.key: true])
        Delivery.migrate(d)
        #expect(d.bool(forKey: Delivery.notificationsKey))
        #expect(!d.bool(forKey: LiveActivityController.pushKey))
    }

    @Test func liveActivitySwitchWithoutPushGaveNothing() {
        let d = defaults([LiveActivityController.pushKey: true])
        Delivery.migrate(d)
        #expect(!d.bool(forKey: Delivery.notificationsKey))
        #expect(!d.bool(forKey: LiveActivityController.pushKey))
    }

    @Test func migratesOnce() {
        let d = defaults([PushRegistration.key: true])
        Delivery.migrate(d)
        d.set(false, forKey: Delivery.notificationsKey)
        Delivery.migrate(d)
        #expect(!d.bool(forKey: Delivery.notificationsKey))
    }

    @Test func helperOnlyWhenItsTheSourceAndSomethingIsOn() {
        #expect(Delivery.helperWanted(stayRunning: false, notifications: true, lockScreen: false))
        #expect(Delivery.helperWanted(stayRunning: false, notifications: false, lockScreen: true))
        #expect(!Delivery.helperWanted(stayRunning: false, notifications: false, lockScreen: false))
        #expect(!Delivery.helperWanted(stayRunning: true, notifications: true, lockScreen: true))
    }

    @Test func alertsOffIsInThePayload() throws {
        let data = PushRegistration.payload(token: "ab", secret: "s", enabled: true, alerts: false, name: "p", key: nil)
        let device = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["device"] as? [String: Any])
        #expect(device["alerts"] as? Bool == false)
        let on = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "p", key: nil)
        #expect(String(decoding: on, as: UTF8.self).contains("alerts") == false)
    }
}
