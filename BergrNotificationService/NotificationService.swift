import UserNotifications

/// Opens the end-to-end encrypted alert text (`e`, see Shared/PushAlertKey.swift) before the
/// notification shows. Without `e` or the key, the generic placeholder from the relay stays.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var best: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        best = content
        if let e = request.content.userInfo["e"] as? String,
           let blob = Data(base64Encoded: e),
           let key = PushAlertKey.stored(),
           let alert = PushAlertKey.decrypt(blob, key: key) {
            content.title = alert.title
            content.body = alert.body
        }
        handler = nil  // delivered: iOS running out of time afterwards mustn't deliver it again
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let best { handler(best) }
        handler = nil
    }
}
