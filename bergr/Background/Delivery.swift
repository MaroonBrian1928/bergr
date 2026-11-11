import Foundation

/// How Bergr keeps you informed while it isn't open, as Settings shows it: where updates come
/// from (the helper on each machine, or Bergr itself kept running), and two independent switches
/// for what you get (notifications, the Live Activity).
///
/// Stored in the keys the app already used: "Bergr stays running" is `KeepAlive.enabled`, the Live
/// Activity is `LiveActivityKeys.push`. Notifications got a key of their own. The helper
/// registration (`PushRegistration.enabled`) follows from these via `apply()`.
@MainActor
enum Delivery {
    static let notificationsKey = "bergr.notifications.enabled"
    private static let migratedKey = "bergr.delivery.migrated"

    /// Notifications when an agent needs you or finishes, from either source.
    static var notifications: Bool {
        get { UserDefaults.standard.bool(forKey: notificationsKey) }
        set { UserDefaults.standard.set(newValue, forKey: notificationsKey); apply() }
    }

    /// The Live Activity, from either source.
    static var lockScreen: Bool {
        get { UserDefaults.standard.bool(forKey: LiveActivityKeys.push) }
        set { UserDefaults.standard.set(newValue, forKey: LiveActivityKeys.push); apply() }
    }

    /// Whether this platform registers with the helpers (APNs). iOS does; the Mac v1 uses local
    /// notifications only (plan 2.8 option A), so it never asks for remote notifications.
    nonisolated static var helperSupported: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// The helper on each machine is needed when it's the source and either switch is on.
    static func helperWanted(stayRunning: Bool, notifications: Bool, lockScreen: Bool,
                             helperSupported: Bool = Delivery.helperSupported) -> Bool {
        helperSupported && !stayRunning && (notifications || lockScreen)
    }

    /// Registers or removes this phone with the helpers to match the switches.
    static func apply() {
        guard helperSupported else { return }
        let wanted = helperWanted(stayRunning: UserDefaults.standard.bool(forKey: KeepAliveKey.value), notifications: notifications,
                                  lockScreen: lockScreen)
        let push = PushRegistration.shared
        if push.enabled != wanted { push.enabled = wanted }
        push.alertsChanged()
    }

    /// Once: carries the old switches over. Before, "Keep connected" always gave notifications and
    /// the Live Activity; otherwise "Push alerts" gave notifications, and the Live Activity switch
    /// (which needed push alerts) the Live Activity.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let stayRunning = defaults.bool(forKey: KeepAliveKey.value)
        let push = defaults.bool(forKey: PushRegistration.key)
        let box = defaults.bool(forKey: LiveActivityKeys.push)
        defaults.set(stayRunning || push, forKey: notificationsKey)
        defaults.set(stayRunning || (push && box), forKey: LiveActivityKeys.push)
    }
}
