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
    /// Which of the demo's machines this is.
    var demoMachine: DemoMachine? { isDemo ? DemoMachine(target: target.host) ?? .studio : nil }
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

    static func makeDemo(_ machine: DemoMachine = .studio) -> Host {
        Host(name: machine.name, target: SSHTarget(host: machine.target, username: "demo"), demo: true)
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

    /// Adds the demo's machines (once) and returns the first, the one to open.
    @discardableResult
    func addDemo() -> Host {
        for machine in DemoMachine.allCases where !hosts.contains(where: { $0.demoMachine == machine }) {
            save(Host.makeDemo(machine))
        }
        return hosts.first { $0.demoMachine == .studio } ?? Host.makeDemo()
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

    /// Adds the machines from a Mac's pairing code, signing in with `keyID`. A machine already
    /// saved with the same address, port and user is skipped. Returns how many were added.
    @discardableResult
    func importPaired(_ paired: [PairingHost], keyID: UUID?) -> Int {
        func same(_ a: SSHTarget, _ b: SSHTarget) -> Bool {
            a.host.lowercased() == b.host.lowercased() && a.port == b.port && a.username == b.username
        }
        var added = 0
        for item in paired {
            let target = SSHTarget(host: item.host, port: item.port, username: item.user)
            guard !hosts.contains(where: { !$0.isLocal && same($0.target, target) }) else { continue }
            hosts.append(Host(name: item.name.isEmpty ? item.host : item.name, target: target, keyID: keyID))
            added += 1
        }
        if added > 0 { persist() }
        return added
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

    /// Where a herdr-core runs: its host (a name or a canonical IP), and the SSH port and user
    /// when known. Each user runs their own core, so `root@` and `alex@` on one machine differ.
    struct Address: Hashable {
        var host: String
        var port: Int?
        var user: String? = nil
        /// The same core: same host, and the same port and user wherever both say which.
        func matches(_ other: Address) -> Bool {
            host == other.host && (port == nil || other.port == nil || port == other.port)
                && (user == nil || other.user == nil || user == other.user)
        }
    }

    /// How a machine added directly can be recognised: `addresses` are its saved address and what
    /// its herdr-core calls itself (its own hostname), with the IPs they resolve to; `names` is
    /// the name it was saved under. No loopback addresses (`localhost` on two machines is two
    /// machines). A machine whose connection failed has none, so a copy linked through another
    /// machine shows again as the fallback.
    struct DirectIdentity: Equatable {
        var addresses: Set<Address> = []
        var names: Set<String> = []
        mutating func formUnion(_ other: DirectIdentity) {
            addresses.formUnion(other.addresses)
            names.formUnion(other.names)
        }
        func contains(any others: Set<Address>) -> Bool {
            others.contains { o in addresses.contains { $0.matches(o) } }
        }
    }

    static let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]

    /// The address in an SSH target: `alex@10.0.0.21:2222` → 10.0.0.21 port 2222,
    /// `[fe80::1]:22` → fe80::1 port 22. IPs in canonical form; nil for nothing or loopback.
    static func address(_ value: String?, port defaultPort: Int? = nil, user defaultUser: String? = nil) -> Address? {
        var t = Substring(value?.trimmingCharacters(in: .whitespaces) ?? "")
        var user = defaultUser.flatMap { $0.isEmpty ? nil : $0 }
        if let at = t.lastIndex(of: "@") {
            if !t[..<at].isEmpty { user = String(t[..<at]) }
            t = t[t.index(after: at)...]
        }
        t = Substring(t.lowercased())
        var port = defaultPort
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            let rest = t[t.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
            t = t[t.index(after: t.startIndex)..<close]
        } else if t.filter({ $0 == ":" }).count == 1, let colon = t.firstIndex(of: ":"),
                  let p = Int(t[t.index(after: colon)...]) {
            port = p
            t = t[..<colon]
        }
        let host = AddressResolver.canonical(String(t)) ?? String(t)
        guard !host.isEmpty, !isLoopback(host) else { return nil }
        return Address(host: host, port: port, user: user)
    }

    /// Just the host of an SSH target (see `address`), or "" for nothing or loopback.
    static func hostPart(_ value: String?) -> String { address(value)?.host ?? "" }

    static func isLoopback(_ host: String) -> Bool {
        loopback.contains(host) || host.hasPrefix("127.") || host == "::"
    }

    /// The addresses of these targets, plus the IPs each name resolves to (`studio.local` and
    /// `10.0.0.20` are the same machine), keeping each one's port.
    private static func addresses(_ values: [(String?, Int?, String?)], resolve: (String) -> Set<String>) -> Set<Address> {
        var out: Set<Address> = []
        for (value, port, user) in values {
            guard let a = address(value, port: port, user: user) else { continue }
            out.insert(a)
            for ip in resolve(a.host) {
                if let r = address(ip), !isLoopback(r.host) { out.insert(Address(host: r.host, port: a.port, user: a.user)) }
            }
        }
        return out
    }

    static func directNames(_ host: Host, coreName: String?, failed: Bool,
                            resolve: (String) -> Set<String> = { _ in [] }) -> DirectIdentity {
        guard !failed, !host.isDemo, !host.isLocal || coreName != nil else { return DirectIdentity() }
        return DirectIdentity(
            addresses: addresses([(host.target.host, host.target.port, host.target.username), (coreName, host.target.port, host.target.username)],
                                 resolve: resolve),
            names: Set([hostPart(host.name)].filter { !$0.isEmpty }))
    }

    /// The machines linked through a core (`laptop` in `laptop/t3`) that are also added directly:
    /// the direct connection is the one to use, so these are left out. An address match counts:
    /// the linked machine's reported host or target (and the IPs they resolve to) against the
    /// direct one's address or core name, with the same SSH port when both give one. With no
    /// reported address, its name counts against the direct address or saved name, as written
    /// (it isn't looked up: a catch-all DNS answers any name). So two machines that merely share
    /// a name, or an IP on different ports, stay apart.
    static func linkedAlsoDirect(_ linked: [MachineView], names terminalMachines: Set<String>,
                                 direct: DirectIdentity,
                                 resolve: (String) -> Set<String> = { _ in [] }) -> Set<String> {
        let byName = Dictionary(linked.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        return Set(terminalMachines.filter { name in
            let machine = byName[name]
            let reported = [machine?.host, machine?.target].contains { !($0?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
            // The host field carries no port: it takes the target's, so a port that differs still says so.
            let target = address(machine?.target)
            if direct.contains(any: addresses([(machine?.host, target?.port, target?.user), (machine?.target, nil, nil)],
                                              resolve: resolve)) { return true }
            // A reported address, even a loopback one, rules out matching on names alone.
            guard !reported else { return false }
            if let own = address(name), direct.contains(any: [own]) { return true }
            return direct.names.contains(hostPart(name))
        })
    }
}

/// The IP addresses machine names resolve to (`studio.local` → `10.0.0.20`), looked up in the
/// background and kept for the app's run: lists read them as they arrive, so two entries for one
/// machine merge once the lookup is back. Addresses that are already IPs aren't looked up.
@MainActor @Observable
final class AddressResolver {
    static let shared = AddressResolver()
    /// Each name's IPs and when they were looked up. Found ones are kept 10 minutes, a failed
    /// lookup (no network yet, off the Wi-Fi a `.local` name lives on) 1 minute, then asked again.
    private var known: [String: (ips: Set<String>, at: Date)] = [:]
    @ObservationIgnored private var asking: Set<String> = []

    func ips(_ name: String) -> Set<String> {
        let name = name.lowercased()
        guard !name.isEmpty, Self.canonical(name) == nil else { return [] }
        let entry = known[name]
        let ttl: TimeInterval = (entry?.ips.isEmpty ?? true) ? 60 : 600
        if (entry.map { Date().timeIntervalSince($0.at) > ttl } ?? true), !asking.contains(name) {
            asking.insert(name)
            Task.detached(priority: .utility) {
                let ips = Self.lookup(name)
                await MainActor.run {
                    let shared = AddressResolver.shared
                    shared.asking.remove(name)
                    shared.known[name] = (ips, Date())
                }
            }
        }
        return entry?.ips ?? []
    }

    /// An IP address in canonical form (`2001:0db8:0:0:0:0:0:1` → `2001:db8::1`), nil for a name.
    nonisolated static func canonical(_ s: String) -> String? {
        var v4 = in_addr(), v6 = in6_addr()
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, s, &v4) == 1, inet_ntop(AF_INET, &v4, &buffer, socklen_t(buffer.count)) != nil {
            return String(cString: buffer)
        }
        if inet_pton(AF_INET6, s, &v6) == 1, inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count)) != nil {
            return String(cString: buffer).lowercased()
        }
        return nil
    }

    nonisolated static func isIP(_ s: String) -> Bool { canonical(s) != nil }

    nonisolated static func lookup(_ name: String) -> Set<String> {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(first) }
        var out: Set<String> = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let n = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(n.pointee.ai_addr, n.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.insert(String(cString: buffer).lowercased())
            }
            node = n.pointee.ai_next
        }
        return out
    }
}
