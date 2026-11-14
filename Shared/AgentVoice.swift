import Foundation

/// What "Send to agent" did, as the intent reports it.
nonisolated enum IntentSendOutcome: Equatable, Sendable {
    case sent
    /// The agent is waiting on a question: the chat was opened, the text is in its draft.
    case waitingOnQuestion
    /// Couldn't reach the agent: the chat was opened, the text is in its draft.
    case unreachable
}

/// The words Siri says for the voice intents, and how an agent's message is cut down to be heard.
nonisolated enum AgentVoice {
    static func sentDialog(_ outcome: IntentSendOutcome, agent: String) -> String {
        switch outcome {
        case .sent: "Sent to \(agent)"
        case .waitingOnQuestion: "\(agent) is waiting on a question — opened it"
        case .unreachable: "Couldn't reach \(agent) — opened it with your message ready"
        }
    }

    /// Markdown reduced to speakable plain text: code blocks dropped, emphasis, headings, bullets
    /// and link targets removed.
    static func plain(_ markdown: String) -> String {
        var lines: [String] = []
        var inFence = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.isEmpty { continue }
            while line.hasPrefix("#") { line.removeFirst() }
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) { line.removeFirst(bullet.count) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            lines.append(".!?:".contains(line.last!) ? line : line + ".")
        }
        var text = lines.joined(separator: " ")
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        for mark in ["**", "__", "`"] { text = text.replacingOccurrences(of: mark, with: "") }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// The first `count` sentences of the message as plain text.
    static func firstSentences(_ message: String, count: Int = 3) -> String {
        let text = plain(message)
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, stop in
            guard let sub = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !sub.isEmpty else { return }
            sentences.append(sub)
            if sentences.count >= count { stop = true }
        }
        return sentences.joined(separator: " ")
    }

    /// What Siri reads for "Read the latest": the on-device summary when it answers within the
    /// timeout (only for messages longer than the cut), else the first three sentences.
    static func readLatest(
        agent: String, message: String?, writer: OnDeviceTextWriting, timeout: Duration = .seconds(2)
    ) async -> String {
        guard let message, !plain(message).isEmpty else { return "\(agent) hasn't said anything yet." }
        let cut = firstSentences(message)
        let full = plain(message)
        guard full.count > cut.count else { return "\(agent) said: \(cut)" }
        let instructions = """
        You write what a voice assistant reads aloud: a short summary of an AI coding agent's last message, \
        in at most three plain sentences, with no lists, markdown, code or quotes. Say what it did or asks.
        """
        let prompt = "Agent \(agent) wrote:\n\(OnDeviceText.truncate(full, to: 1500))"
        if let summary = await writer.write(instructions: instructions, prompt: prompt, timeout: timeout),
           let clean = OnDeviceText.clean(summary, maxCharacters: 400) {
            return "\(agent) said: \(clean)"
        }
        return "\(agent) said: \(cut)"
    }
}
