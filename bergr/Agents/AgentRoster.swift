import Foundation
import HerdrKit

/// One agent in the Mac's menu-bar popover and in "next agent needing you".
struct AgentEntry: Identifiable, Equatable {
    var ref: AgentRef
    var title: String
    var machine: String
    var state: AgentState
    var id: AgentRef { ref }
}

/// Pure helpers for the Mac shell (menu-bar item, commands), tested without sessions.
enum AgentRoster {
    struct Machine {
        var id: UUID
        var name: String
        var terminals: [Terminal]
    }

    /// Live agents that need you or work, needs-you first (the list's order within each).
    static func attention(_ machines: [Machine]) -> [AgentEntry] {
        let entries: [AgentEntry] = machines.flatMap { machine in
            AgentsOrdering.ordered(machine.terminals.filter(\.isLive)).compactMap { terminal in
                guard let state = terminal.agentState, state != .done, state != .idle else { return nil }
                return AgentEntry(ref: AgentRef(host: machine.id, address: terminal.address),
                                  title: AgentsOrdering.title(terminal), machine: machine.name, state: state)
            }
        }
        func needs(_ e: AgentEntry) -> Bool { e.state == .needsYou || e.state == .error }
        return entries.filter(needs) + entries.filter { !needs($0) }
    }

    /// The agent `step` places after `current` in `list`, wrapping around. With no current agent
    /// (or one not in the list) forward starts at the first and backward at the last.
    static func step(from current: AgentRef?, in list: [AgentRef], by step: Int) -> AgentRef? {
        guard !list.isEmpty else { return nil }
        guard let current, let index = list.firstIndex(of: current) else {
            return step >= 0 ? list.first : list.last
        }
        let count = list.count
        return list[((index + step) % count + count) % count]
    }

    /// The menu-bar item's text: working agents, then "n!" for those that need you ("2 · 1!").
    /// Empty when nothing needs attention, so the item is just its icon.
    static func menuBarTitle(_ counts: AgentCounts) -> String {
        var parts: [String] = []
        if counts.working > 0 { parts.append("\(counts.working)") }
        if counts.needsYou > 0 { parts.append("\(counts.needsYou)!") }
        return parts.joined(separator: " · ")
    }
}
