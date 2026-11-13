import Foundation

/// What may notify, beyond the one global switch: which kinds, which agents are muted, and quiet
/// hours (only "Needs you" gets through). Applies to local notifications and, sent in the
/// registration, to the helper's pushes. The defaults change nothing for existing users.
struct NotificationPrefs: Codable, Equatable, Sendable {
    var needsYou = true
    var finished = true
    var errors = true
    /// Muted agents: "<machine id>|<agent address>" to the name it had when muted (for Settings).
    var muted: [String: String] = [:]
    var quietEnabled = false
    /// Minutes after midnight, in the phone's time zone. The window may cross midnight.
    var quietStart = 22 * 60
    var quietEnd = 7 * 60

    static let storageKey = "bergr.notifications.prefs"

    nonisolated static func muteKey(host: UUID, address: String) -> String { "\(host.uuidString)|\(address)" }

    nonisolated static func load(_ defaults: UserDefaults = .standard) -> NotificationPrefs {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(NotificationPrefs.self, from: $0) } ?? NotificationPrefs()
    }

    nonisolated func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.storageKey)
    }

    nonisolated func isMuted(host: UUID, address: String) -> Bool {
        muted[Self.muteKey(host: host, address: address)] != nil
    }

    nonisolated mutating func setMuted(_ on: Bool, host: UUID, address: String, name: String) {
        let key = Self.muteKey(host: host, address: address)
        if on { muted[key] = name } else { muted[key] = nil }
    }

    nonisolated func kindOn(_ kind: AgentNotifier.Kind) -> Bool {
        switch kind {
        case .needsYou: needsYou
        case .finished: finished
        case .error: errors
        }
    }

    /// Whether `minute` (minutes after midnight) is inside quiet hours; start == end is empty.
    nonisolated func isQuiet(minute: Int) -> Bool {
        guard quietEnabled, quietStart != quietEnd else { return false }
        return quietStart < quietEnd
            ? (quietStart..<quietEnd).contains(minute)
            : (minute >= quietStart || minute < quietEnd)
    }

    nonisolated static func minute(of date: Date, in zone: TimeZone = .current) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// The one rule for local and remote: the kind's switch, the agent's mute, then quiet hours.
    nonisolated func allows(kind: AgentNotifier.Kind, host: UUID, address: String, minute: Int) -> Bool {
        guard kindOn(kind), !isMuted(host: host, address: address) else { return false }
        return kind == .needsYou || !isQuiet(minute: minute)
    }

    /// A stable string of what one machine is sent, to notice when it must be sent again.
    nonisolated func fingerprint(host: UUID?) -> String {
        let data = try? JSONSerialization.data(withJSONObject: payload(host: host, now: .distantPast), options: [.sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What the registration carries for one machine (see `prefs` in bergr-notify.py, v13).
    nonisolated func payload(host: UUID?, zone: TimeZone = .current, now: Date = Date()) -> [String: Any] {
        var object: [String: Any] = [
            "kinds": ["needs_you": needsYou, "finished": finished, "error": errors],
            "muted": muted.keys.compactMap { key -> String? in
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, host == nil || parts[0] == host?.uuidString else { return nil }
                return parts[1]
            }.sorted(),
            "tz": zone.identifier,
            "tz_offset": zone.secondsFromGMT(for: now) / 60,
        ]
        if quietEnabled { object["quiet"] = ["start": quietStart, "end": quietEnd] }
        return object
    }
}
