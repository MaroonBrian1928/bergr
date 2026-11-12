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
}
