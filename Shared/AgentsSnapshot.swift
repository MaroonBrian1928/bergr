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

    static let empty = AgentsSnapshot(needsYou: 0, working: 0, done: 0, rows: [], updated: .distantPast)
    private static let key = "agents-snapshot"

    init(needsYou: Int, working: Int, done: Int, rows: [BergrActivityAttributes.Row], updated: Date) {
        self.needsYou = needsYou
        self.working = working
        self.done = done
        self.rows = rows
        self.updated = updated
    }

    init(_ state: BergrActivityAttributes.ContentState?, updated: Date = .now) {
        self.init(
            needsYou: state?.needsYou ?? 0, working: state?.working ?? 0, done: state?.done ?? 0,
            rows: state?.rows ?? [], updated: updated)
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
