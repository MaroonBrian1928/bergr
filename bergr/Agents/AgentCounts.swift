import HerdrKit

/// How many agents wait for you, work, or finished a turn nobody has looked at: the numbers of the
/// Mac's menu-bar item. Pure, so it is tested without sessions.
struct AgentCounts: Equatable, Sendable {
    var needsYou = 0
    var working = 0
    var done = 0

    /// Live terminals only; blocked and errored agents count as needing you, like the Live Activity.
    init(terminals: [Terminal]) {
        for terminal in terminals where terminal.isLive {
            switch terminal.agentState {
            case .needsYou, .error: needsYou += 1
            case .working: working += 1
            case .done: done += 1
            case .idle, nil: break
            }
        }
    }

    init(needsYou: Int = 0, working: Int = 0, done: Int = 0) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
    }

    /// Across every machine that has a session.
    @MainActor
    init(sessions: SessionStore) {
        self.init(terminals: sessions.ids.compactMap { sessions.existing($0) }.flatMap(\.terminals))
    }
}
