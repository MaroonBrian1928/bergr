import Foundation

/// The `bergr://terminal?host=<uuid>&address=<t7>` deep link to one agent.
nonisolated enum AgentLink {
    static func target(of url: URL) -> (host: UUID, address: String)? {
        guard url.scheme == "bergr", url.host == "terminal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value.flatMap(UUID.init(uuidString:)),
              let address = items.first(where: { $0.name == "address" })?.value, !address.isEmpty
        else { return nil }
        return (host, address)
    }
}

/// UserDefaults keys of the Live Activity settings, which shared settings code reads.
nonisolated enum LiveActivityKeys {
    static let push = "bergr.liveActivity.push"
    static let content = "bergr.liveActivity.content"
    static let history = "bergr.liveActivity.history"
}

/// The "Bergr stays running" switch (`KeepAlive` on iOS; the Mac keeps running anyway).
nonisolated enum KeepAliveKey {
    static let value = "bergr.keepConnectedInBackground"
}
