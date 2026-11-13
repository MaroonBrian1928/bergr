import Foundation

/// What each widget family shows of the snapshot, chosen here so it can be tested without WidgetKit.
nonisolated enum AgentWidgetContent {
    /// The first `limit` agents that need you or are working. The snapshot lists needs-you rows
    /// first, then working, then done, so only as many rows as there are active agents are taken.
    static func activeRows(_ snapshot: AgentsSnapshot, limit: Int) -> [BergrActivityAttributes.Row] {
        let active = snapshot.needsYou + snapshot.working
        return Array(AgentCatalog.sorted(snapshot.rows).prefix(min(limit, active)))
    }

    /// Accessory inline: "2 need you · 1 working", or the calm line when nothing is active.
    static func inlineText(_ snapshot: AgentsSnapshot) -> String {
        var parts: [String] = []
        if snapshot.needsYou > 0 { parts.append("\(snapshot.needsYou) need\(snapshot.needsYou == 1 ? "s" : "") you") }
        if snapshot.working > 0 { parts.append("\(snapshot.working) working") }
        return parts.isEmpty ? "Nothing needs you" : parts.joined(separator: " · ")
    }

    /// Medium widget: up to `limit` agents, needs-you first, then working, then done (stable within
    /// a state). Snapshots from older builds have no `agents`: their rows stand in.
    static func mediumAgents(_ snapshot: AgentsSnapshot, limit: Int = 4) -> [AgentsSnapshot.Agent] {
        let source = snapshot.agents.isEmpty ? snapshot.rows.map {
            AgentsSnapshot.Agent(state: $0.needsYou ? "needsYou" : "working", name: $0.title, machine: $0.machine,
                                 lastLine: $0.status, host: $0.host, address: $0.address)
        } : snapshot.agents
        func rank(_ a: AgentsSnapshot.Agent) -> Int { ["needsYou": 0, "working": 1, "done": 2][a.state] ?? 3 }
        let ordered = source.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        return Array(ordered.map(\.element).prefix(limit))
    }

    static func stateWord(_ state: String) -> String {
        switch state {
        case "needsYou": "Needs you"
        case "working": "Working"
        default: "Done"
        }
    }
}
