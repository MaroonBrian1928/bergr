import Foundation
import HerdrKit

/// Finished and idle agents nobody has touched for a while (Settings → Hide finished agents
/// after): left out of the counts, the widget and the Live Activity, and folded away in the
/// Agents list. An agent that needs you or is working always counts, however old.
enum QuietAgents {
    nonisolated static let key = "bergr.agents.hideAfter"
    /// The choices, in seconds; 0 is never.
    nonisolated static let choices: [(seconds: Int, title: String)] = [
        (3600, "1 hour"), (4 * 3600, "4 hours"), (86400, "1 day"), (7 * 86400, "1 week"), (0, "Never")]
    nonisolated static let defaultSeconds = 86400

    nonisolated static var seconds: Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? defaultSeconds
    }

    /// Done or idle, with its last status change (or its start) longer ago than `after` seconds.
    nonisolated static func isQuiet(_ terminal: Terminal, now: Date = .now, after: Int = seconds) -> Bool {
        guard after > 0 else { return false }
        switch terminal.agentState {
        case .done, .idle, nil: break
        default: return false
        }
        let ms = terminal.statusMs ?? terminal.createdMs
        guard ms > 0 else { return false }
        return now.timeIntervalSince1970 - Double(ms) / 1000 > Double(after)
    }
}
