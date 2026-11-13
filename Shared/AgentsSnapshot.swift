import Foundation

/// The App Group id, put into both Info.plists from `group.$(BERGR_BUNDLE_ID_PREFIX).bergr`.
nonisolated enum BergrAppGroup {
    static var id: String? { Bundle.main.object(forInfoDictionaryKey: "BergrAppGroup") as? String }
    static let widgetKind = "BergrAgentsWidget"
}

/// What the Home Screen widget shows: written by the app on each update, read by the extension.
nonisolated struct AgentsSnapshot: Codable, Hashable {
    var needsYou: Int
    var working: Int
    var done: Int
    /// Up to 3, needs-you first.
    var rows: [BergrActivityAttributes.Row]
    var updated: Date
    /// Up to 4 agents for the medium widget, each with its last line. Empty in snapshots written
    /// by older builds.
    var agents: [Agent] = []
    /// Machine names by host id (UUID string), for the notification extension's grouped summary.
    var machines: [String: String] = [:]

    /// One agent as the medium widget lists it.
    nonisolated struct Agent: Codable, Hashable {
        /// "needsYou", "working" or "done".
        var state: String
        var name: String
        var machine: String
        /// The last one-line summary or status sentence; empty when there is none.
        var lastLine: String
        var host: String
        var address: String

        var url: URL {
            var c = URLComponents()
            c.scheme = "bergr"
            c.host = "terminal"
            c.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "address", value: address)]
            return c.url ?? URL(string: "bergr://terminal")!
        }
    }

    static let empty = AgentsSnapshot(needsYou: 0, working: 0, done: 0, rows: [], updated: .distantPast)
    private static let key = "agents-snapshot"

    init(needsYou: Int, working: Int, done: Int, rows: [BergrActivityAttributes.Row], updated: Date,
         agents: [Agent] = [], machines: [String: String] = [:]) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
        self.rows = rows
        self.updated = updated
        self.agents = agents
        self.machines = machines
    }

    init(_ state: BergrActivityAttributes.ContentState?, updated: Date = .now,
         agents: [Agent] = [], machines: [String: String] = [:]) {
        self.init(
            needsYou: state?.needsYou ?? 0, working: state?.working ?? 0, done: state?.done ?? 0,
            rows: state?.rows ?? [], updated: updated, agents: agents, machines: machines)
    }

    /// Fields added later decode as empty from older snapshots.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        needsYou = try c.decode(Int.self, forKey: .needsYou)
        working = try c.decode(Int.self, forKey: .working)
        done = try c.decode(Int.self, forKey: .done)
        rows = try c.decode([BergrActivityAttributes.Row].self, forKey: .rows)
        updated = try c.decode(Date.self, forKey: .updated)
        agents = try c.decodeIfPresent([Agent].self, forKey: .agents) ?? []
        machines = try c.decodeIfPresent([String: String].self, forKey: .machines) ?? [:]
    }

    static func load() -> AgentsSnapshot {
        guard let id = BergrAppGroup.id, let data = UserDefaults(suiteName: id)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(AgentsSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    func save() {
        guard let id = BergrAppGroup.id, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: id)?.set(data, forKey: Self.key)
    }
}
