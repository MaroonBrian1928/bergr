import Foundation

/// What an agent shows, by herdr's shared read state (herdr-app's `docs/labels.md`): clients
/// keep `herdr.seen=<turn>` on the terminal, so what one has looked at is read on all of them.
public enum AgentState: String, CaseIterable, Sendable {
    /// Blocked: waits for an answer.
    case needsYou
    case error
    /// Finished a turn nobody has looked at yet.
    case done
    case working
    /// Looked at, or nothing new.
    case idle
}

extension Terminal {
    /// The last turn a person looked at.
    public static let seenLabel = "herdr.seen"

    /// From `herdr.seen`; nil when missing (which is not 0).
    public var seenTurn: UInt64? {
        labels[Self.seenLabel].flatMap { UInt64($0) }
    }

    /// Nil for a terminal without a status. Blocked, error and working go by the status;
    /// otherwise done when a turn ended after the one last seen. Without a seen label (or a
    /// core that doesn't count turns), the program's own `done` counts as unread.
    public var agentState: AgentState? {
        guard let state = status?.state else { return nil }
        switch state {
        case "blocked": return .needsYou
        case "error": return .error
        case "working": return .working
        default:
            if let turn, let seen = seenTurn { return turn > seen ? .done : .idle }
            return state == "done" ? .done : .idle
        }
    }

    /// The labels to write while someone looks at it: raises `herdr.seen` to the current turn,
    /// or adds it when missing. Nil when there's nothing to raise.
    public var markSeen: [String: String]? {
        guard let turn else { return nil }
        if let seen = seenTurn, seen >= turn { return nil }
        return [Self.seenLabel: String(turn)]
    }

    /// Mark as read: like looking at it, for an unread agent.
    public var markRead: [String: String]? {
        agentState == .done ? markSeen : nil
    }

    /// Mark as unread: the one write that lowers it, to the turn before. Not at turn 0
    /// (nothing has finished yet), and only for an agent that's read.
    public var markUnread: [String: String]? {
        guard agentState == .idle, let turn, turn > 0 else { return nil }
        return [Self.seenLabel: String(turn - 1)]
    }
}
