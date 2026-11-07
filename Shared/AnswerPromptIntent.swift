import AppIntents
import Foundation

/// What a tap on an answer button asks for: which question it was for, and which answer.
nonisolated struct AnswerRequest: Sendable, Equatable {
    var host: String
    var address: String
    var question: String
    var number: Int
    var label: String
    /// Empty for a numbered choice; "y", "n" or "esc" otherwise.
    var key: String
}

/// The app installs this when it starts; the extension never runs it (a LiveActivityIntent
/// runs in the app's process, which is why the type is compiled into both targets).
nonisolated enum AnswerIntentBridge {
    nonisolated(unsafe) static var handler: (@MainActor (AnswerRequest) async -> Void)?
}

/// Tapping an answer button on the Lock Screen or in the Dynamic Island.
nonisolated struct AnswerPromptIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Answer agent"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Host") var host: String
    @Parameter(title: "Terminal") var address: String
    @Parameter(title: "Question") var question: String
    @Parameter(title: "Number") var number: Int
    @Parameter(title: "Answer") var label: String
    @Parameter(title: "Key") var key: String

    init() {
        host = ""; address = ""; question = ""; number = 0; label = ""; key = ""
    }

    init(host: String, address: String, question: String, option: BergrActivityAttributes.Option) {
        self.host = host
        self.address = address
        self.question = question
        self.number = option.number
        self.label = option.label
        self.key = option.key
    }

    func perform() async throws -> some IntentResult {
        let request = AnswerRequest(
            host: host, address: address, question: question, number: number, label: label, key: key)
        if let handler = AnswerIntentBridge.handler { await handler(request) }
        return .result()
    }
}
