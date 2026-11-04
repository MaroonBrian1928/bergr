import Foundation
import HerdrKit
import Observation
import SwiftUI

/// A machine running herdr-core that we reach over SSH.
struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var target: SSHTarget
    var keyID: UUID?
    /// herdr-core session on that machine (nil: its default).
    var session: String?
    /// The built-in demo machine: a pretend herdr-core inside the app, no SSH.
    /// Optional so hosts saved before it existed still decode.
    var demo: Bool?

    var isDemo: Bool { demo == true }

    var subtitle: String {
        if isDemo { return "Built in · try Hirte without a server" }
        return "\(target.username)@\(target.host)" + (target.port == 22 ? "" : ":\(target.port)")
    }

    static func makeDemo() -> Host {
        Host(name: "Demo machine", target: SSHTarget(host: "demo", username: "demo"), demo: true)
    }
}

/// Saved hosts, persisted in UserDefaults. They hold no secrets.
@Observable
final class HostStore {
    private(set) var hosts: [Host] = []
    private let defaults: UserDefaults
    private let key = "hirte.hosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
        }
    }

    func save(_ host: Host) {
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
        persist()
    }

    var hasDemo: Bool { hosts.contains(where: \.isDemo) }

    /// Adds the demo machine (once) and returns it.
    @discardableResult
    func addDemo() -> Host {
        if let existing = hosts.first(where: \.isDemo) { return existing }
        let demo = Host.makeDemo()
        save(demo)
        return demo
    }

    func delete(at offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(hosts), forKey: key)
    }
}
