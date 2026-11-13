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
        // Older installed helpers or relay versions may still mark alerts time-sensitive.
        // Keep those as ordinary notifications without requiring the optional entitlement.
        if content.interruptionLevel == .timeSensitive { content.interruptionLevel = .active }
        // One stack per machine: "3 more from <machine>".
        if let group = PushGrouping.result(userInfo: request.content.userInfo, machines: AgentsSnapshot.load().machines) {
            content.threadIdentifier = group.thread
            content.summaryArgument = group.summaryArgument
        }
        best = content
        if let e = request.content.userInfo["e"] as? String,
           let blob = Data(base64Encoded: e),
           let key = PushAlertKey.stored(),
           let alert = PushAlertKey.decrypt(blob, key: key) {
            content.title = alert.title
            content.body = alert.body
            // A question with 2 to 4 options gets answer buttons (the app registers the category);
            // the body says what each number answers.
            // No buttons (done, a dangerous command, a question): a text Reply; health alerts: neither.
            let category = AnswerCategory.pushCategory(
                question: alert.q, address: request.content.userInfo["address"] as? String)
            content.categoryIdentifier = category
            if let q = alert.q, category == AnswerCategory.identifier(for: q) {
                content.body = [alert.body, AnswerCategory.summary(q)].filter { !$0.isEmpty }.joined(separator: "\n")
                content.userInfo.merge(AnswerCategory.userInfo(q)) { _, new in new }
            }
        }
        handler = nil  // delivered: iOS running out of time afterwards mustn't deliver it again
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let best { handler(best) }
        handler = nil
    }
}
