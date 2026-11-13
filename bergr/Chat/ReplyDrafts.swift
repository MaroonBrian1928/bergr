import Foundation

/// Unsent replies, one per agent (machine and terminal), kept across switching agents and
/// relaunches. Sending empties the draft, which removes it.
@MainActor
enum ReplyDrafts {
    static let key = "bergr.replyDrafts"

    static func text(for agent: String?, in defaults: UserDefaults = .standard) -> String {
        guard let agent else { return "" }
        return (defaults.dictionary(forKey: key) as? [String: String])?[agent] ?? ""
    }

    /// The draft text put back from replies that were never delivered, per agent. A draft counts as
    /// "unsent" only while it is still exactly this: sending or editing it ends that.
    static let restoredKey = "bergr.replyDraftsRestored"

    private static func restored(in defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: restoredKey) as? [String: String] ?? [:]
    }

    /// Whether the agent's draft holds replies that were put back unsent.
    static func hasUnsent(for agent: String?, in defaults: UserDefaults = .standard) -> Bool {
        guard let agent else { return false }
        let draft = text(for: agent, in: defaults)
        return !draft.isEmpty && restored(in: defaults)[agent] == draft
    }

    /// Puts replies that weren't delivered back into the agent's draft, in send order, after what
    /// is already there (blank line between). One already in the draft isn't added again.
    static func restore(_ replies: [String], for agent: String?, in defaults: UserDefaults = .standard) {
        guard let agent else { return }
        let before = text(for: agent, in: defaults)
        var draft = before
        for reply in replies {
            let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty, !draft.contains(reply) else { continue }
            draft = draft.isEmpty ? reply : draft + "\n\n" + reply
        }
        guard draft != before else { return }
        set(draft, for: agent, in: defaults)
        var marks = restored(in: defaults)
        marks[agent] = draft
        defaults.set(marks, forKey: restoredKey)
    }

    static func set(_ text: String, for agent: String?, in defaults: UserDefaults = .standard) {
        guard let agent else { return }
        var marks = restored(in: defaults)
        if let mark = marks[agent], mark != text {
            marks[agent] = nil
            defaults.set(marks, forKey: restoredKey)
        }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all[agent, default: ""] != text else { return }
        all[agent] = text.isEmpty ? nil : text
        defaults.set(all, forKey: key)
    }
}
