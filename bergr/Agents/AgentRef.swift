import Foundation

/// One agent: a machine and the terminal's address on it. The Mac's per-agent window is keyed by it
/// (`WindowGroup(for: AgentRef.self)`), so reopening an agent focuses its window.
struct AgentRef: Codable, Hashable, Sendable {
    var host: UUID
    var address: String
}
