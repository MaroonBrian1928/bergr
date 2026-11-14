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
    /// The helper's answerID and the machine id the push named: the answer can go through the relay.
    var answerID: String? = nil
    var machine: String? = nil
}

/// What a typed reply from an alert's Reply action asks for.
nonisolated struct ReplyNotificationRequest: Equatable, Sendable {
    var host: UUID
    var address: String
    var text: String
    /// The alert asked a question (a Codex question is answered from the chat, not typed).
    var question: String? = nil
}

/// Notification categories that give an alert answer buttons. Categories are fixed when the app
/// registers them, so the buttons are titled by number ("1", "2"); the alert's body lists what each
/// number answers (`summary`).
nonisolated enum AnswerCategory {
    static let prefix = "bergr.answer."
    /// Buttons that answer in the background through the relay (alerts with an answerID): the phone
    /// must be unlocked, but the app doesn't open.
    static let remotePrefix = "bergr.answer.remote."
    static let actionPrefix = "bergr.answer.action."
    static let counts = 2...4
    /// The category with just a Reply text field (done alerts, blocked ones without buttons).
    static let replyCategory = "bergr.reply"
    static let replyAction = "bergr.reply.action"
    /// Whether the app can send a typed reply (iOS and Mac); when off, alerts only open the chat.
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

    /// Machine health alerts (disk, battery) use this address; they have no agent to reply to.
    static let healthAddress = "health"
    /// Their category: no actions, so no Reply field that goes nowhere.
    static let healthCategory = "bergr.health"

    /// The category a pushed alert gets once decrypted: answer buttons for a 2 to 4 option
    /// question, none for a health alert, otherwise Reply.
    static func pushCategory(question: AnswerQuestion?, address: String?, answerID: String? = nil) -> String {
        if address == healthAddress { return healthCategory }
        guard let plain = identifier(for: question) else { return replyCategory }
        #if os(iOS)
        if RemoteAnswer.isAnswerID(answerID), question?.keys == true {
            return "\(remotePrefix)\(question!.options.count)"
        }
        #endif
        return plain
    }

    /// Whether a category is one of the answer-button ones (foreground or remote).
    static func isAnswerCategory(_ identifier: String) -> Bool {
        identifier.hasPrefix(prefix)
    }

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
        func answers(_ identifier: String, count: Int, options: UNNotificationActionOptions) -> UNNotificationCategory {
            var actions: [UNNotificationAction] = (0..<count).map {
                UNNotificationAction(identifier: actionIdentifier(index: $0), title: "\($0 + 1)", options: options)
            }
            if replyEnabled { actions.append(replyButton()) }
            return UNNotificationCategory(
                identifier: identifier, actions: actions, intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: PushGrouping.summaryFormat, options: [])
        }
        var set = Set(counts.map { answers("\(prefix)\($0)", count: $0, options: [.foreground, .authenticationRequired]) })
        #if os(iOS)
        // No .foreground: the helper answers. .authenticationRequired: only from an unlocked phone.
        set.formUnion(counts.map { answers("\(remotePrefix)\($0)", count: $0, options: [.authenticationRequired]) })
        #endif
        set.insert(UNNotificationCategory(
            identifier: healthCategory, actions: [], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: PushGrouping.summaryFormat, options: []))
        if replyEnabled {
            set.insert(UNNotificationCategory(
                identifier: replyCategory, actions: [replyButton()], intentIdentifiers: [],
                hiddenPreviewsBodyPlaceholder: nil, categorySummaryFormat: PushGrouping.summaryFormat, options: []))
        }
        return set
    }

    static func register() {
        UNUserNotificationCenter.current().setNotificationCategories(categories())
    }

    private static let titleKey = "answerTitle", optionsKey = "answerOptions", keysKey = "answerKeys"
    static let answerIDKey = "answerID"

    /// The question's entries for a notification's userInfo (and the helper's answerID, if any).
    static func userInfo(_ question: AnswerQuestion, answerID: String? = nil) -> [String: Any] {
        var info: [String: Any] = [titleKey: question.title, optionsKey: question.options, keysKey: question.keys]
        if RemoteAnswer.isAnswerID(answerID) { info[answerIDKey] = answerID }
        return info
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
        var request = AnswerNotificationRequest(host: target.host, address: target.address, question: question, index: index)
        if let id = info[answerIDKey] as? String, RemoteAnswer.isAnswerID(id), let machine = info["host"] as? String,
           !machine.isEmpty {
            request.answerID = id
            request.machine = machine
        }
        return request
    }
}

/// Answering through the relay: the phone seals {machine, answerID, choice} with its alert key and
/// leaves it in the relay's mailbox; the machine's helper (version 20 on) checks the prompt and presses.
nonisolated enum RemoteAnswer {
    /// The first helper version that sends answerIDs and fetches answers.
    static let minHelperVersion = 21
    static let versionsKey = "bergr.push.helperVersions"

    static func isAnswerID(_ id: String?) -> Bool {
        guard let id, id.count == 32 else { return false }
        return id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// What the button answers: Yes / No for a key question, the option's index otherwise.
    static func choice(question: AnswerQuestion, index: Int) -> PushAlertKey.AnswerChoice? {
        guard question.options.indices.contains(index) else { return nil }
        guard question.keys else { return .option(index) }
        switch question.options[index].lowercased() {
        case "yes": return .yes
        case "no": return .no
        default: return nil
        }
    }

    /// Whether to send this answer through the relay: it has an answerID and the machine's helper
    /// isn't known to be older (an answerID only comes from a new helper; an older reported version wins).
    static func usesRelay(_ request: AnswerNotificationRequest, helperVersion: Int?) -> Bool {
        guard isAnswerID(request.answerID), request.machine?.isEmpty == false,
              choice(question: request.question, index: request.index) != nil else { return false }
        return helperVersion.map { $0 >= minHelperVersion } ?? true
    }

    /// The body of POST /v1/answer.
    static func body(machine: String, answerID: String, choice: PushAlertKey.AnswerChoice, key: Data) -> Data? {
        guard let sealed = PushAlertKey.sealAnswer(choice, machine: machine, answerID: answerID, key: key) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: ["machine": machine, "id": answerID, "e": sealed.base64EncodedString()], options: [.sortedKeys])
    }

    // MARK: Helper versions (kept so a tap that launches the app in the background knows them)

    static func helperVersion(_ host: UUID, defaults: UserDefaults = .standard) -> Int? {
        (defaults.dictionary(forKey: versionsKey) as? [String: Int])?[host.uuidString]
    }

    static func setHelperVersion(_ version: Int?, for host: UUID, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: versionsKey) as? [String: Int] ?? [:]
        all[host.uuidString] = version
        defaults.set(all, forKey: versionsKey)
    }

    // MARK: Latest answerID per terminal (the extension records it; the Live Activity's buttons use it)

    static let latestKey = "bergr.answer.latest"
    static let ttl: TimeInterval = 600

    static func recordLatest(machine: String, address: String, answerID: String, now: Date = .now,
                             defaults: UserDefaults? = BergrAppGroup.id.flatMap { UserDefaults(suiteName: $0) }) {
        guard isAnswerID(answerID), let defaults else { return }
        var all = defaults.dictionary(forKey: latestKey) as? [String: [String: Any]] ?? [:]
        all = all.filter { (($0.value["at"] as? Double) ?? 0) > now.timeIntervalSince1970 - ttl }
        all["\(machine)|\(address)"] = ["id": answerID, "at": now.timeIntervalSince1970]
        defaults.set(all, forKey: latestKey)
    }

    static func latest(machine: String, address: String, now: Date = .now,
                       defaults: UserDefaults? = BergrAppGroup.id.flatMap { UserDefaults(suiteName: $0) }) -> String? {
        guard let entry = (defaults?.dictionary(forKey: latestKey) as? [String: [String: Any]])?["\(machine)|\(address)"],
              let id = entry["id"] as? String, let at = entry["at"] as? Double,
              at > now.timeIntervalSince1970 - ttl, isAnswerID(id) else { return nil }
        return id
    }
}

extension AnswerCategory {
    /// A Reply action's response, once the notification's target is known.
    static func replyRequest(
        actionIdentifier: String, text: String?, target: (host: UUID, address: String), question: String? = nil
    ) -> ReplyNotificationRequest? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard actionIdentifier == replyAction, !trimmed.isEmpty else { return nil }
        return ReplyNotificationRequest(host: target.host, address: target.address, text: trimmed, question: question)
    }
}

/// The iOS app installs this; without it (the Mac) an answer button just opens the chat.
@MainActor
enum AnswerNotificationBridge {
    static var handler: ((AnswerNotificationRequest) async -> Void)?
    static var replyHandler: ((ReplyNotificationRequest) -> Void)?
}
