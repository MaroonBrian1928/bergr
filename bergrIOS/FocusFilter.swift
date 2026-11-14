import AppIntents
import Foundation

/// A machine the Focus filter can pick, read from the saved machines.
nonisolated struct FocusMachineEntity: AppEntity, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Machine"
    static let defaultQuery = FocusMachineQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

nonisolated struct FocusMachineQuery: EntityStringQuery {
    private static func all() -> [FocusMachineEntity] {
        guard let data = UserDefaults.standard.data(forKey: "bergr.hosts"),
              let hosts = try? JSONDecoder().decode([Host].self, from: data) else { return [] }
        return hosts.map { FocusMachineEntity(id: $0.id.uuidString, name: $0.name) }
    }

    func entities(for identifiers: [String]) async throws -> [FocusMachineEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FocusMachineEntity] {
        Self.all().filter { $0.name.localizedStandardContains(string) }
    }

    func suggestedEntities() async throws -> [FocusMachineEntity] { Self.all() }
}

/// Settings > Focus > (a mode) > Focus Filters > Bergr. While that Focus is on, only the chosen
/// machines and kinds notify (on top of Bergr's own settings); when it turns off, back to normal.
/// The system calls `perform()` again with the defaults when the Focus ends, and the defaults
/// (all machines, all kinds) change nothing, so that clears the profile.
nonisolated struct BergrFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set notifications"
    static let description: IntentDescription? = IntentDescription("Choose which machines and kinds of alert Bergr sends during this Focus.")

    @Parameter(title: "Machines", description: "Leave empty for all machines.")
    var machines: [FocusMachineEntity]?

    @Parameter(title: "Needs you", default: true)
    var needsYou: Bool

    @Parameter(title: "Finished", default: true)
    var finished: Bool

    @Parameter(title: "Errors", default: true)
    var errors: Bool

    var displayRepresentation: DisplayRepresentation {
        let chosen = (machines ?? []).map(\.name)
        let kinds = [needsYou ? "Needs you" : nil, finished ? "Finished" : nil, errors ? "Errors" : nil].compactMap { $0 }
        return DisplayRepresentation(
            title: "\(kinds.isEmpty ? "No alerts" : kinds.joined(separator: ", "))",
            subtitle: chosen.isEmpty ? "All machines" : "\(chosen.joined(separator: ", "))")
    }

    var profile: FocusProfile {
        let ids = (machines ?? []).compactMap { UUID(uuidString: $0.id) }
        return FocusProfile(machines: ids.isEmpty ? nil : ids, needsYou: needsYou, finished: finished, errors: errors)
    }

    func perform() async throws -> some IntentResult {
        FocusProfile.setActive(profile)
        await MainActor.run { PushRegistration.shared.focusChanged() }
        return .result()
    }
}
