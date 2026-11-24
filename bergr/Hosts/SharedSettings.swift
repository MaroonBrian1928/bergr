import Foundation
import CoreTransferable
import UniformTypeIdentifiers
import HerdrKit

/// Settings the dev build and the TestFlight/App Store build share on one phone: the machines and
/// the machines' host keys, in the App Group both are in (`group.<prefix>.bergr`). The SSH keys
/// are shared through a keychain group (see `KeychainKeyStorage`), so one setup serves both.
enum SharedSettings {
    static let hostsKey = "bergr.hosts"
    static let knownHostsKey = "bergr.known-hosts"

    /// The App Group's defaults, with what this build saved on its own merged in once; plain
    /// `.standard` where there is no group (the Mac app, tests).
    static let defaults: UserDefaults = {
        guard let id = BergrAppGroup.id, let group = UserDefaults(suiteName: id) else { return .standard }
        merge(from: .standard, into: group)
        return group
    }()

    /// Adds this build's own machines and host keys to the group's: machines by id (the group's
    /// copy wins), host keys by host (the group's wins). Once per build.
    static let mergedKey = "bergr.sharedSettingsMerged"

    static func merge(from own: UserDefaults, into group: UserDefaults) {
        // Once per build: a machine deleted from the shared list later must not come back from
        // this build's old copy.
        guard !own.bool(forKey: mergedKey) else { return }
        defer { own.set(true, forKey: mergedKey) }
        if let data = own.data(forKey: hostsKey),
           let mine = try? JSONDecoder().decode([Host].self, from: data) {
            let theirs = group.data(forKey: hostsKey).flatMap { try? JSONDecoder().decode([Host].self, from: $0) } ?? []
            let known = Set(theirs.map(\.id))
            let merged = theirs + mine.filter { !known.contains($0.id) && !$0.isDemo }
            if merged.count != theirs.count || group.data(forKey: hostsKey) == nil,
               let out = try? JSONEncoder().encode(merged) {
                group.set(out, forKey: hostsKey)
            }
        }
        if let mine = own.dictionary(forKey: knownHostsKey) as? [String: String], !mine.isEmpty {
            let theirs = group.dictionary(forKey: knownHostsKey) as? [String: String] ?? [:]
            let merged = theirs.merging(mine) { group, _ in group }
            if merged.count != theirs.count { group.set(merged, forKey: knownHostsKey) }
        }
    }
}

/// Machines in a file, to move them to another phone or build: the machines and the host keys
/// they were trusted with. No private key: those never leave the device (or its Secure Enclave).
struct MachinesExport: Codable, Transferable {
    /// Encoded only when shared, as a .json file.
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { try $0.data() }
            .suggestedFileName(fileName)
    }

    var version = 1
    var machines: [Host]
    var hostKeys: [String: String]

    static let fileName = "Bergr Machines.json"

    static func make(hosts: [Host], defaults: UserDefaults = SharedSettings.defaults) -> MachinesExport {
        MachinesExport(machines: hosts.filter { !$0.isDemo && !$0.isLocal },
                       hostKeys: defaults.dictionary(forKey: SharedSettings.knownHostsKey) as? [String: String] ?? [:])
    }

    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Adds the file's machines (an existing one with the same id is updated) and the host keys it
    /// doesn't know yet. A machine whose key isn't on this device signs in with `fallbackKey`.
    /// Returns how many machines were added or updated.
    @MainActor
    func apply(to store: HostStore, knownKeys: Set<UUID>, fallbackKey: UUID?,
               defaults: UserDefaults = SharedSettings.defaults) -> Int {
        let current = defaults.dictionary(forKey: SharedSettings.knownHostsKey) as? [String: String] ?? [:]
        defaults.set(current.merging(hostKeys) { mine, _ in mine }, forKey: SharedSettings.knownHostsKey)
        var count = 0
        for var machine in machines where !machine.isDemo && !machine.isLocal {
            // A key that isn't on this device, or none (a Mac's machine signing in with its own ssh).
            if machine.keyID.map({ !knownKeys.contains($0) }) ?? true {
                machine.keyID = fallbackKey
                if fallbackKey != nil { machine.systemSSH = nil }
            }
            if store.hosts.first(where: { $0.id == machine.id }) != machine {
                store.save(machine)
                count += 1
            }
        }
        return count
    }
}
