import Foundation
#if os(iOS)
import ActivityKit
#endif

/// The Live Activity's data. Compiled into the app and the widget extension; no other dependencies.
nonisolated struct BergrActivityAttributes {
    nonisolated struct Row: Codable, Hashable {
        /// "claude", "codex", "antigravity" or "shell".
        var kind: String
        var title: String
        var status: String
        var machine: String
        var needsYou: Bool
        /// Host id (UUID string) and terminal address, for the deep link.
        var host: String
        var address: String

        /// `bergr://terminal?host=<uuid>&address=<t7>`
        var url: URL {
            var c = URLComponents()
            c.scheme = "bergr"
            c.host = "terminal"
            c.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "address", value: address)]
            return c.url ?? URL(string: "bergr://terminal")!
        }
    }

    nonisolated struct ContentState: Codable, Hashable {
        var needsYou: Int
        var working: Int
        var done: Int
        /// Up to 3: needs-you first, then working.
        var rows: [Row]
        /// The most urgent blocked agent's question, to answer from the Lock Screen; nil when none.
        var prompt: Prompt? = nil
    }

    /// A blocked agent's question with the answers offered as buttons.
    nonisolated struct Prompt: Codable, Hashable {
        var host: String
        var address: String
        /// The agent's name, for the header.
        var title: String
        var question: String
        var options: [Option]
    }

    /// One button: a numbered choice from the screen (`key` empty), or Yes / No / Esc (`key` is
    /// "y", "n" or "esc", `number` 0).
    nonisolated struct Option: Codable, Hashable {
        var number: Int
        var label: String
        var key: String
    }
}

#if os(iOS)
extension BergrActivityAttributes: ActivityAttributes {}
#endif
