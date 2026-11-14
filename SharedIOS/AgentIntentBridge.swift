import Foundation

/// How the intents reach the running app's sessions. The app sets these when its root view is up;
/// an intent that launched the app waits for them.
@MainActor
enum AgentIntentBridge {
    static var send: ((_ host: UUID, _ address: String, _ text: String) async -> IntentSendOutcome)?
    static var latestMessage: ((_ host: UUID, _ address: String) async -> String?)?

    /// True once the app has registered the handlers (waits up to `timeout`).
    static func ready(timeout: Duration = .seconds(10)) async -> Bool {
        let start = ContinuousClock.now
        while send == nil || latestMessage == nil {
            if ContinuousClock.now - start > timeout { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
