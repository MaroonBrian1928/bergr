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

    static func set(_ text: String, for agent: String?, in defaults: UserDefaults = .standard) {
        guard let agent else { return }
        var all = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard all[agent, default: ""] != text else { return }
        all[agent] = text.isEmpty ? nil : text
        defaults.set(all, forKey: key)
    }
}
