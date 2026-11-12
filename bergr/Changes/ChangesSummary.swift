import Foundation

/// The one-sentence summary at the top of the Changes sheet, written on the device. Pure helpers
/// here; `ChangesModel` runs the writer.
enum ChangesSummary {
    static let instructions = """
        You summarise a code change for a developer reading it on a phone. Reply with exactly one \
        plain-language sentence in the active voice that starts with a verb, for example: \
        "Refactors the auth middleware and adds a redirect test". No markdown, no quotes, no lists.
        """
    static let timeout: Duration = .seconds(5)
    static let diffLineLimit = 120
    static let statLimit = 1_500
    static let diffLimit = 6_000
    static let replyLimit = 1_200

    /// The prompt from the diff stat, the first lines of the combined diff (empty on expensive
    /// networks) and the agent's last reply. Nil when there is nothing to summarise.
    static func prompt(stat: String, diffHead: String, reply: String?) -> String? {
        let stat = stat.trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = reply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !stat.isEmpty || !reply.isEmpty else { return nil }
        var parts: [String] = []
        if !stat.isEmpty { parts.append("Diff stat:\n" + OnDeviceText.truncate(stat, to: statLimit)) }
        if !diffHead.isEmpty { parts.append("First lines of the diff:\n" + OnDeviceText.truncate(diffHead, to: diffLimit)) }
        if !reply.isEmpty { parts.append("The agent's last reply:\n" + OnDeviceText.truncate(reply, to: replyLimit)) }
        parts.append("Summarise the change in one sentence.")
        return parts.joined(separator: "\n\n")
    }

    /// The first `diffLineLimit` lines of a combined diff.
    static func diffHead(_ diff: String) -> String {
        diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(diffLineLimit).joined(separator: "\n")
    }

    /// The text of the agent's latest assistant message, if any.
    static func lastReply(in items: [ChatFeed.Item]) -> String? {
        for item in items.reversed() {
            if case .assistant(let text, _) = item.kind,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }
}
