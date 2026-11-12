import Foundation
import HerdrKit

/// The body of an agent's alert, as one sentence the on-device model writes from the agent's recent
/// chat ("Fixed the login redirect; 3 files changed, tests pass"). Without a chat, or when the model
/// can't answer in time, the caller's own body stays.
enum NotificationSummary {
    /// How long an alert may wait for the model. A needs-you alert is never held back longer.
    static let timeout: Duration = .seconds(3)
    /// The last chat items the model sees.
    static let window = 12
    static let lineCharacters = 200
    static let promptCharacters = 2000

    static let instructions = """
        You write the one-line notification text for a coding agent's terminal session. \
        Answer with one plain-text sentence of at most 25 words. No markdown, no quotes, no lists.
        """

    /// The last `window` items of a chat as short lines, oldest first. Images and placeholders have
    /// no text and are left out.
    static func transcript(_ items: [ChatFeed.Item], last: Int = window) -> [String] {
        items.suffix(last).compactMap { line(for: $0.kind) }
    }

    static func line(for kind: ChatFeed.Kind) -> String? {
        let text: String
        switch kind {
        case .user(let message): text = "User: \(message)"
        case .assistant(let reply, _): text = "Reply: \(reply)"
        case .tool(let name, let summary): text = "Tool \(name): \(summary)"
        case .plan(let steps):
            text = "Plan: " + steps.map { "[\($0.status)] \($0.text)" }.joined(separator: "; ")
        case .decision(let question, let answer): text = "Answered \"\(question)\": \(answer)"
        case .note(let note): text = "Note: \(note)"
        case .question(let title, _): text = "Asked: \(title)"
        case .image, .imageLoading, .imageOnDemand: return nil
        }
        return OnDeviceText.truncate(text, to: lineCharacters)
    }

    static func prompt(agent: String, kind: AgentNotifier.Kind, transcript: [String]) -> String {
        let event = switch kind {
        case .finished: "finished its turn and is waiting for the user"
        case .needsYou: "needs the user to answer or approve something"
        case .error: "hit an error"
        }
        let chat = OnDeviceText.truncate(transcript.joined(separator: "\n"), to: promptCharacters)
        return """
            Agent: \(agent). It \(event).
            Its recent chat, oldest first:
            \(chat)

            Write the notification text.
            """
    }

    /// The summary for an alert, or `fallback` when there's no chat or the model gives nothing.
    static func body(
        agent: String, kind: AgentNotifier.Kind, transcript: [String], fallback: String,
        writer: OnDeviceTextWriting
    ) async -> String {
        guard !transcript.isEmpty else { return fallback }
        let prompt = prompt(agent: agent, kind: kind, transcript: transcript)
        return await writer.write(instructions: instructions, prompt: prompt, timeout: timeout) ?? fallback
    }
}
