import Foundation

/// What the Usage widget shows: written by the app whenever plan usage is read, read by the extension.
nonisolated struct UsageSnapshot: Codable, Hashable {
    nonisolated struct Window: Codable, Hashable {
        /// "Claude session", "Codex weekly".
        var title: String
        var percent: Double
        /// The forecast ("Limit at 15:10") or the reset ("Resets at 14:00"); empty when unknown.
        var detail: String
    }

    var windows: [Window]
    var updated: Date

    static let empty = UsageSnapshot(windows: [], updated: .distantPast)
    static let widgetKind = "BergrUsageWidget"
    private static let key = "usage-snapshot"

    /// The window closest to its limit.
    var highest: Window? { windows.max { $0.percent < $1.percent } }

    static func load() -> UsageSnapshot {
        guard let id = BergrAppGroup.id, let data = UserDefaults(suiteName: id)?.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(UsageSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    func save() {
        guard let id = BergrAppGroup.id, let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: id)?.set(data, forKey: Self.key)
    }
}
