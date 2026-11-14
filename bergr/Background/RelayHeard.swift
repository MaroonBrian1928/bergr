import Foundation

/// When the push relay last heard from each of this phone's machines (the helper sends a heartbeat
/// every 5 minutes), so silence is visible: a dead helper, a sleeping machine or failing pushes
/// otherwise look like "all fine".
struct RelayHeard: Equatable, Sendable {
    /// The helper's heartbeat is 5 minutes; alerts count as not reaching the phone after three beats.
    nonisolated static let staleAfter: TimeInterval = 15 * 60

    /// Seconds since the relay last heard from each machine, by the app's machine id (`Host.id.uuidString`).
    let ageByMachine: [String: TimeInterval]

    nonisolated func age(of machine: UUID) -> TimeInterval? {
        ageByMachine[machine.uuidString] ?? ageByMachine.first { $0.key.caseInsensitiveCompare(machine.uuidString) == .orderedSame }?.value
    }

    /// Reads the relay's `GET /v1/machines` answer. Ages use the relay's own clock.
    nonisolated static func parse(_ data: Data) -> RelayHeard? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let now = (object["now"] as? NSNumber)?.doubleValue,
              let machines = object["machines"] as? [[String: Any]] else { return nil }
        var ages: [String: TimeInterval] = [:]
        for machine in machines {
            guard let id = machine["id"] as? String, let at = (machine["at"] as? NSNumber)?.doubleValue else { continue }
            ages[id] = max(0, (now - at) / 1000)
        }
        return RelayHeard(ageByMachine: ages)
    }

    /// "just now", "7 min ago", "2h ago", "3d ago".
    nonisolated static func agoText(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    /// "Alerts last heard 2h ago"; "Alerts last heard just now".
    nonisolated static func lastHeardText(_ seconds: TimeInterval) -> String {
        "Alerts last heard \(agoText(seconds))"
    }

    /// The Setup row "Alerts reaching your phone", for a machine reachable over SSH. nil age: the
    /// relay never heard a heartbeat (an older helper, or none sent yet), which isn't a fault.
    nonisolated static func alertsState(age: TimeInterval?) -> CheckState {
        guard let age else { return .ready("No heartbeat yet. It starts once the helper is up to date.") }
        if age > staleAfter {
            return .warning("The relay last heard from this machine \(agoText(age)), though it's reachable. "
                + "Check that the push helper is running.")
        }
        return .ready("Heard \(agoText(age))")
    }
}

extension PushRegistration {
    /// What the relay last heard from this phone's machines; nil when push isn't set up, the relay
    /// is old (404) or unreachable.
    nonisolated static func fetchHeard(secret: String) async -> RelayHeard? {
        var request = URLRequest(url: relayURL.appending(path: "v1/machines"))
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return RelayHeard.parse(data)
    }
}
