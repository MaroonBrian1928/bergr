// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
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
    /// "This Mac": herdr-core runs on this machine, reached by starting `herdr-core connect`
    /// directly (no SSH, no key). Optional so hosts saved before it existed still decode.
    var local: Bool?
    /// Native Mac only: use OpenSSH and its agent without importing a private key.
    /// Optional for existing saved machines; those retain their selected Bergr key.
    var systemSSH: Bool?

    var usesSystemSSH: Bool {
        #if os(macOS)
        systemSSH ?? (keyID == nil)
        #else
        false
        #endif
    }

    var isDemo: Bool { demo == true }
    var isLocal: Bool {
        #if os(macOS)
        !isDemo && (local == true || LocalMachine.matches(target.host))
        #else
        local == true
        #endif
    }

    var subtitle: String {
        if isLocal { return "Runs here · no SSH needed" }
        if isDemo { return "Built in · try Bergr without a server" }
        return "\(target.username)@\(target.host)" + (target.port == 22 ? "" : ":\(target.port)")
    }

    static func makeLocal() -> Host {
        Host(name: "This Mac", target: SSHTarget(host: "localhost", username: NSUserName()), local: true)
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
    private let key = "bergr.hosts"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Host].self, from: data) {
            hosts = saved
        }
        // No demo machine in this build: drop one saved earlier.
        if hosts.contains(where: \.isDemo) {
            hosts.removeAll(where: \.isDemo)
            persist()
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

    var hasLocal: Bool { hosts.contains(where: \.isLocal) }

    /// Adds "This Mac" (once) and returns it.
    @discardableResult
    func addLocal() -> Host {
        if let existing = hosts.first(where: \.isLocal) { return existing }
        let local = Host.makeLocal()
        hosts.insert(local, at: 0)
        persist()
        return local
    }

    /// Adds the demo machine (once) and returns it.
    @discardableResult
    func addDemo() -> Host {
        if let existing = hosts.first(where: \.isDemo) { return existing }
        let demo = Host.makeDemo()
        save(demo)
        return demo
    }

    /// Reorders the machines (the agent list follows this order).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        hosts.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Moves one machine a place up (-1) or down (+1).
    func move(_ host: Host, by step: Int) {
        guard let index = hosts.firstIndex(of: host) else { return }
        let target = index + step
        guard hosts.indices.contains(target) else { return }
        hosts.swapAt(index, target)
        persist()
    }

    func delete(at offsets: IndexSet) {
        hosts.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(hosts), forKey: key)
    }
}


/// Two saved machines that reach the same herdr-core (this Mac directly, and the same Mac over
/// SSH): the agent list shows it once.
enum SameMachine {
    /// The machines to leave out, each with the one it duplicates: a later entry with the same
    /// core name as an earlier one, preferring the local connection.
    static func duplicates(_ machines: [(host: Host, coreName: String?)]) -> [UUID: Host] {
        var kept: [String: Host] = [:]
        var hidden: [UUID: Host] = [:]
        let ordered = machines.filter { $0.host.isLocal } + machines.filter { !$0.host.isLocal }
        for (host, name) in ordered {
            guard let name, !name.isEmpty, !host.isDemo else { continue }
            if let first = kept[name] { hidden[host.id] = first } else { kept[name] = host }
        }
        return hidden
    }
}
