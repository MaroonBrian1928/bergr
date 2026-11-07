import Foundation
import Observation
import UserNotifications

/// Where a tapped notification wants to go. RootView reads `pending` and clears it.
@MainActor @Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    var pending: (host: UUID, address: String)?

    /// What the app is showing now, so banners are skipped for the terminal on screen.
    @ObservationIgnored var focused: (host: UUID, address: String)?
}

/// Receives taps on notifications and decides whether to show banners in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static func target(_ info: [AnyHashable: Any]) -> (host: UUID, address: String)? {
        guard let host = (info["host"] as? String).flatMap(UUID.init(uuidString:)),
              let address = info["address"] as? String else { return nil }
        return (host, address)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let target = Self.target(response.notification.request.content.userInfo) else { return }
        await MainActor.run { NotificationRouter.shared.pending = target }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let target = Self.target(notification.request.content.userInfo)
        let onScreen = await MainActor.run {
            guard let target, let focused = NotificationRouter.shared.focused else { return false }
            return focused.host == target.host && focused.address == target.address
        }
        return onScreen ? [] : [.banner, .list, .sound]
    }
}
