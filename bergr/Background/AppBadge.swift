import Foundation
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The app icon badge (iOS) and Dock tile badge (Mac): how many agents need you. Settings →
/// Notifications → "Show badge" (default on); off shows nothing. While the app is away the relay
/// sets the same number on each push (see `PushRegistration.syncBadgePref`).
enum AppBadge {
    nonisolated static let key = "bergr.badge.enabled"

    nonisolated static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// The number to show: the needs-you count, or 0 when the setting is off.
    nonisolated static func count(needsYou: Int, enabled: Bool) -> Int {
        enabled ? max(0, needsYou) : 0
    }

    @MainActor private static var lastNeedsYou = 0
    @MainActor private static var lastShown: Int?

    /// Shows the badge for this many agents needing you (0 clears it).
    @MainActor static func apply(needsYou: Int) {
        lastNeedsYou = needsYou
        let shown = count(needsYou: needsYou, enabled: enabled())
        guard shown != lastShown else { return }
        lastShown = shown
        UNUserNotificationCenter.current().setBadgeCount(shown) { _ in }
        #if os(macOS)
        NSApp?.dockTile.badgeLabel = shown == 0 ? nil : String(shown)
        #endif
    }

    /// The setting changed: show or clear now, and tell the relay.
    @MainActor static func settingChanged() {
        apply(needsYou: lastNeedsYou)
        PushRegistration.shared.syncBadgePref()
    }
}
