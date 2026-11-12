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
        let info = response.notification.request.content.userInfo
        await MainActor.run {
            // Local alerts carry Bergr's host id; pushes name the machine by hostname.
            guard let target = Self.target(info) ?? PushRegistration.shared.target(info) else { return }
            // An answer button: the app answers (iOS), or opens the chat when it can't or the
            // question isn't the same any more.
            if let request = AnswerCategory.replyRequest(
                actionIdentifier: response.actionIdentifier,
                text: (response as? UNTextInputNotificationResponse)?.userText, target: target),
               let handler = AnswerNotificationBridge.replyHandler {
                handler(request)
                return
            }
            if let request = AnswerCategory.request(
                actionIdentifier: response.actionIdentifier, info: info, target: target),
               let handler = AnswerNotificationBridge.handler {
                handler(request)
                return
            }
            NotificationRouter.shared.pending = target
        }
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
