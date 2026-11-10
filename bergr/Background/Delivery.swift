import Foundation

/// How Bergr keeps you informed while it isn't open, as Settings shows it: where updates come
/// from (the helper on each machine, or Bergr itself kept running), and two independent switches
/// for what you get (notifications, the Lock Screen box).
///
/// Stored in the keys the app already used: "Bergr stays running" is `KeepAlive.enabled`, the Lock
/// Screen box is `LiveActivityController.pushKey`. Notifications got a key of their own. The helper
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

    /// The Lock Screen box (Live Activity), from either source.
    static var lockScreen: Bool {
        get { UserDefaults.standard.bool(forKey: LiveActivityController.pushKey) }
        set { UserDefaults.standard.set(newValue, forKey: LiveActivityController.pushKey); apply() }
    }

    /// The helper on each machine is needed when it's the source and either switch is on.
    static func helperWanted(stayRunning: Bool, notifications: Bool, lockScreen: Bool) -> Bool {
        !stayRunning && (notifications || lockScreen)
    }

    /// Registers or removes this phone with the helpers to match the switches.
    static func apply() {
        let wanted = helperWanted(stayRunning: KeepAlive.shared.enabled, notifications: notifications,
                                  lockScreen: lockScreen)
        let push = PushRegistration.shared
        if push.enabled != wanted { push.enabled = wanted }
        push.alertsChanged()
    }

    /// Once: carries the old switches over. Before, "Keep connected" always gave notifications and
    /// the Lock Screen box; otherwise "Push alerts" gave notifications, and the Live Activity switch
    /// (which needed push alerts) the box.
    static func migrate(_ defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let stayRunning = defaults.bool(forKey: KeepAlive.key)
        let push = defaults.bool(forKey: PushRegistration.key)
        let box = defaults.bool(forKey: LiveActivityController.pushKey)
        defaults.set(stayRunning || push, forKey: notificationsKey)
        defaults.set(stayRunning || (push && box), forKey: LiveActivityController.pushKey)
    }
}
