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
    /// Ask each machine's helper to keep it awake while agents work (helper v17 on).
    var keepAwake = true

    init() {}

    /// Tolerant: prefs saved by an older build lack newer keys and keep their defaults.
    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        needsYou = try c.decodeIfPresent(Bool.self, forKey: .needsYou) ?? true
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? true
        errors = try c.decodeIfPresent(Bool.self, forKey: .errors) ?? true
        muted = try c.decodeIfPresent([String: String].self, forKey: .muted) ?? [:]
        quietEnabled = try c.decodeIfPresent(Bool.self, forKey: .quietEnabled) ?? false
        quietStart = try c.decodeIfPresent(Int.self, forKey: .quietStart) ?? 22 * 60
        quietEnd = try c.decodeIfPresent(Int.self, forKey: .quietEnd) ?? 7 * 60
        keepAwake = try c.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
    }

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
    /// An active Focus profile narrows it further (see `effective`).
    nonisolated func allows(kind: AgentNotifier.Kind, host: UUID, address: String, minute: Int,
                            focus: FocusProfile? = FocusProfile.active()) -> Bool {
        let p = effective(host: host, focus: focus)
        guard p.kindOn(kind), !p.isMuted(host: host, address: address) else { return false }
        return kind == .needsYou || !p.isQuiet(minute: minute)
    }

    /// These prefs with a Focus profile on top, for one machine: a kind is on only when both allow
    /// it, and a machine the Focus leaves out has every kind off. No profile changes nothing.
    nonisolated func effective(host: UUID?, focus: FocusProfile?) -> NotificationPrefs {
        guard let focus else { return self }
        var next = self
        let included = host.map(focus.includes(machine:)) ?? true
        next.needsYou = needsYou && focus.needsYou && included
        next.finished = finished && focus.finished && included
        next.errors = errors && focus.errors && included
        return next
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
            "keepAwake": keepAwake,
        ]
        if quietEnabled { object["quiet"] = ["start": quietStart, "end": quietEnd] }
        return object
    }
}

/// What a Focus mode's "Bergr" filter asks for while that Focus is on: which machines may alert
/// (nil: all) and which kinds get through. It narrows the normal prefs, never widens them.
struct FocusProfile: Codable, Equatable, Sendable {
    var machines: [UUID]?
    var needsYou: Bool
    var finished: Bool
    var errors: Bool

    nonisolated init(machines: [UUID]? = nil, needsYou: Bool = true, finished: Bool = true, errors: Bool = true) {
        self.machines = machines
        self.needsYou = needsYou
        self.finished = finished
        self.errors = errors
    }

    nonisolated func includes(machine: UUID) -> Bool { machines?.contains(machine) ?? true }

    /// Everything allowed on every machine: the same as no Focus at all.
    nonisolated var isNeutral: Bool { machines == nil && needsYou && finished && errors }

    static let storageKey = "bergr.focus.profile"

    /// The profile of the Focus that is on now, if any.
    nonisolated static func active(_ defaults: UserDefaults = .standard) -> FocusProfile? {
        defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(FocusProfile.self, from: $0) }
    }

    /// Sets the active profile; nil (or a profile that changes nothing) clears it.
    nonisolated static func setActive(_ profile: FocusProfile?, _ defaults: UserDefaults = .standard) {
        if let profile, !profile.isNeutral {
            defaults.set(try? JSONEncoder().encode(profile), forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
    }
}
