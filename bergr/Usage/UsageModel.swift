import Foundation
import HerdrKit

/// One agent on one machine, as the Usage screen lists it. `usage` comes from the agent's running
/// chat feed, else from a one-shot read of its transcript. `running` means numbers (or a feed)
/// exist; `failed` that the one-shot read failed; `empty` that the agent has no numbers yet.
struct UsageReading: Identifiable, Equatable {
    let id: String
    let machine: String
    let agent: ChatAgent
    let running: Bool
    let usage: ChatFeed.Usage?
    var failed = false
    var empty = false
}

/// A plan window shared by one or more agents: the same agent, reset time and percent show as one account.
struct UsageAccount: Identifiable, Equatable {
    let id: String
    let session: ChatFeed.Usage.Window?
    let weekly: ChatFeed.Usage.Window?
    /// The machines and agents that show this plan window (one, unless it appears on several machines).
    let readings: [UsageReading]
}

enum UsageAccounts {
    /// Groups readings that report the same plan windows (same percent and reset time) into one
    /// account. Readings without plan windows stay on their own.
    static func group(_ readings: [UsageReading]) -> [UsageAccount] {
        var order: [String] = []
        var groups: [String: [UsageReading]] = [:]
        for reading in readings {
            let key: String
            if let usage = reading.usage, usage.session != nil || usage.weekly != nil {
                key = "\(reading.agent.rawValue)|\(signature(usage.session))|\(signature(usage.weekly))"
            } else {
                key = "alone|\(reading.id)"
            }
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(reading)
        }
        return order.map { key in
            let members = groups[key] ?? []
            let usage = members.first?.usage
            return UsageAccount(id: key, session: usage?.session, weekly: usage?.weekly, readings: members)
        }
    }

    static func signature(_ window: ChatFeed.Usage.Window?) -> String {
        guard let window else { return "-" }
        return "\(window.percent)@\(window.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0)"
    }
}

/// The readings for every running agent on the machines: terminals that are live and run an agent,
/// with the chat feed's usage where a feed is being followed.
enum UsageReadings {
    /// The chat feed being followed for a terminal, if any (agents without one read "open the chat
    /// to read usage").
    @MainActor
    static func feed(_ sessions: SessionStore?, machine: UUID, address: String) -> ChatFeed? {
        sessions?.existing(machine)?.runningFeed(address: address)
    }

    /// Backlog snapshots are not live account readings. Publish only after the helper caught up.
    @MainActor
    static func currentUsage(_ feed: ChatFeed?) -> ChatFeed.Usage? {
        guard let feed, feed.caughtUp, feed.phase == .live else { return nil }
        return feed.usage
    }

    /// The live feed's numbers when there are any, else the one-shot read.
    static func resolve(feed: ChatFeed?, probed: UsageProbeOutcome?)
        -> (running: Bool, usage: ChatFeed.Usage?, failed: Bool, empty: Bool) {
        if let live = currentUsage(feed) { return (true, live, false, false) }
        switch probed {
        case .usage(let usage): return (true, usage, false, false)
        case .failed where feed == nil: return (false, nil, true, false)
        case .empty where feed == nil: return (false, nil, false, true)
        default: return (feed != nil, nil, false, false)
        }
    }

    @MainActor
    static func readings(hosts: [Host], sessions: SessionStore?, probe: UsageProbe? = .shared) -> [UsageReading] {
        hosts.flatMap { host in
            (sessions?.existing(host.id)?.terminals ?? []).filter(\.isLive).compactMap { terminal in
                guard let agent = ChatAgent.detect(terminal) else { return nil }
                let id = "\(host.id)/\(terminal.address)"
                let feed = feed(sessions, machine: host.id, address: terminal.address)
                let r = resolve(feed: feed, probed: probe?.outcomes[id])
                return UsageReading(id: id, machine: host.name, agent: agent, running: r.running,
                                    usage: r.usage, failed: r.failed, empty: r.empty)
            }
        }
    }

    /// The agents to read with the one-shot helper: live agent terminals without a running feed.
    @MainActor
    static func targets(hosts: [Host], sessions: SessionStore?) -> [UsageTarget] {
        hosts.flatMap { host -> [UsageTarget] in
            guard let session = sessions?.existing(host.id) else { return [] }
            return session.terminals.filter(\.isLive).compactMap { terminal in
                guard let agent = ChatAgent.detect(terminal),
                      feed(sessions, machine: host.id, address: terminal.address) == nil else { return nil }
                let front = terminal.foreground.flatMap {
                    ChatAgent.detect(name: $0.name, argv: $0.argv) == agent ? $0 : nil
                }
                return UsageTarget(
                    id: "\(host.id)/\(terminal.address)", agent: agent, pid: front?.pid ?? 0,
                    cwd: front?.cwd ?? terminal.cwd,
                    sessionHint: ChatAgent.sessionHint(argv: terminal.foreground?.argv ?? []),
                    working: terminal.agentState == .working, session: session)
            }
        }
    }
}
