import Foundation
import UserNotifications

/// The question a blocked agent asks, as the helper puts it into the alert (`q`) and as the app's own
/// alerts know it: a title, up to four options, and whether they are answered by key (Yes / No).
nonisolated struct AnswerQuestion: Codable, Equatable, Sendable {
    var title: String
    var options: [String]
    var keys: Bool
}

/// What a tap on one of an alert's answer buttons asks for.
nonisolated struct AnswerNotificationRequest: Equatable, Sendable {
    var host: UUID
    var address: String
    var question: AnswerQuestion
    /// Zero-based, into `question.options`.
    var index: Int
}

/// What a typed reply from an alert's Reply action asks for.
nonisolated struct ReplyNotificationRequest: Equatable, Sendable {
    var host: UUID
    var address: String
    var text: String
}

/// Notification categories that give an alert answer buttons. Categories are fixed when the app
/// registers them, so the buttons are titled by number ("1", "2"); the alert's body lists what each
/// number answers (`summary`).
nonisolated enum AnswerCategory {
    static let prefix = "bergr.answer."
    static let actionPrefix = "bergr.answer.action."
    static let counts = 2...4
    /// The category with just a Reply text field (done alerts, blocked ones without buttons).
    static let replyCategory = "bergr.reply"
    static let replyAction = "bergr.reply.action"
    /// Whether the app can send a typed reply (iOS); the Mac turns it off and alerts only open the chat.
    nonisolated(unsafe) static var replyEnabled = true

    /// The category for a question with this many options; nil when it can't have buttons.
    static func identifier(optionCount: Int) -> String? {
        counts.contains(optionCount) ? "\(prefix)\(optionCount)" : nil
    }

    static func identifier(for question: AnswerQuestion?) -> String? {
        question.flatMap { identifier(optionCount: $0.options.count) }
    }

    static func actionIdentifier(index: Int) -> String { "\(actionPrefix)\(index)" }

    static func index(ofAction identifier: String) -> Int? {
        guard identifier.hasPrefix(actionPrefix) else { return nil }
        return Int(identifier.dropFirst(actionPrefix.count))
    }

    /// The category for an alert without answer buttons: Reply, when the app can send it.
    static var replyIdentifier: String? { replyEnabled ? replyCategory : nil }

    private static func replyButton() -> UNTextInputNotificationAction {
        UNTextInputNotificationAction(
            identifier: replyAction, title: "Reply", options: [.foreground, .authenticationRequired],
            textInputButtonTitle: "Send", textInputPlaceholder: "Reply to the agent")
    }

    /// "1 Yes · 2 No", appended to the alert's body.
    static func summary(_ question: AnswerQuestion) -> String {
        question.options.enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: " · ")
    }

    /// Registered by the app at launch (the extension only names a category).
    static func categories() -> Set<UNNotificationCategory> {
        var set = Set(counts.map { count in
            var actions: [UNNotificationAction] = (0..<count).map {
                UNNotificationAction(
                    identifier: actionIdentifier(index: $0), title: "\($0 + 1)",
                    options: [.foreground, .authenticationRequired])
            }
            if replyEnabled { actions.append(replyButton()) }
            return UNNotificationCategory(
                identifier: "\(prefix)\(count)", actions: actions, intentIdentifiers: [], options: [])
        })
        if replyEnabled {
            set.insert(UNNotificationCategory(
                identifier: replyCategory, actions: [replyButton()], intentIdentifiers: [], options: []))
        }
        return set
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(categories())
    }

    private static let titleKey = "answerTitle", optionsKey = "answerOptions", keysKey = "answerKeys"

    /// The question's entries for a notification's userInfo.
    static func userInfo(_ question: AnswerQuestion) -> [String: Any] {
        [titleKey: question.title, optionsKey: question.options, keysKey: question.keys]
    }

    static func question(in info: [AnyHashable: Any]) -> AnswerQuestion? {
        guard let title = info[titleKey] as? String, let options = info[optionsKey] as? [String],
              !options.isEmpty else { return nil }
        return AnswerQuestion(title: title, options: options, keys: info[keysKey] as? Bool ?? false)
    }

    /// An answer button's response, once the notification's target is known.
    static func request(
        actionIdentifier: String, info: [AnyHashable: Any], target: (host: UUID, address: String)
    ) -> AnswerNotificationRequest? {
        guard let index = index(ofAction: actionIdentifier), let question = question(in: info),
              question.options.indices.contains(index) else { return nil }
        return AnswerNotificationRequest(host: target.host, address: target.address, question: question, index: index)
    }
}

extension AnswerCategory {
    /// A Reply action's response, once the notification's target is known.
    static func replyRequest(
        actionIdentifier: String, text: String?, target: (host: UUID, address: String)
    ) -> ReplyNotificationRequest? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard actionIdentifier == replyAction, !trimmed.isEmpty else { return nil }
        return ReplyNotificationRequest(host: target.host, address: target.address, text: trimmed)
    }
}

/// The iOS app installs this; without it (the Mac) an answer button just opens the chat.
@MainActor
enum AnswerNotificationBridge {
    static var handler: ((AnswerNotificationRequest) -> Void)?
    static var replyHandler: ((ReplyNotificationRequest) -> Void)?
}
