import Foundation
import HerdrKit

/// One agent on one machine, as the Usage screen lists it. `usage` is nil and `running` false
/// when the agent's chat feed isn't running (the screen then asks to open the chat).
struct UsageReading: Identifiable, Equatable {
    let id: String
    let machine: String
    let agent: ChatAgent
    let running: Bool
    let usage: ChatFeed.Usage?
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

    @MainActor
    static func readings(hosts: [Host], sessions: SessionStore?) -> [UsageReading] {
        hosts.flatMap { host in
            (sessions?.existing(host.id)?.terminals ?? []).filter(\.isLive).compactMap { terminal in
                guard let agent = ChatAgent.detect(terminal) else { return nil }
                let feed = feed(sessions, machine: host.id, address: terminal.address)
                return UsageReading(id: "\(host.id)/\(terminal.address)", machine: host.name, agent: agent,
                                    running: feed != nil, usage: currentUsage(feed))
            }
        }
    }
}
