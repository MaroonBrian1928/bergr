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

/// Which Bergr on this phone gets notifications, when two are installed (the dev build and the
/// TestFlight/App Store build share an App Group): only that one registers with the helpers and
/// posts alerts, so each alert arrives once. The release build takes them the first time it runs
/// this; either takes them back when its Notifications switch is turned on.
nonisolated enum PushOwner {
    static let key = "bergr.push.owner"
    private static let claimedKey = "bergr.push.ownerClaimed"

    static var me: String { Bundle.main.bundleIdentifier ?? "" }
    static var isDevBuild: Bool { me.hasSuffix(".dev") }

    private static var group: UserDefaults? { BergrAppGroup.id.flatMap(UserDefaults.init(suiteName:)) }

    /// The build that gets them; nil when none has claimed them (or there's no group).
    static var owner: String? { group?.string(forKey: key) }

    /// Nobody claimed them, or this build did.
    static var isMine: Bool { owner.map { $0 == me } ?? true }

    static func claim() { group?.set(me, forKey: key) }

    /// At launch: the release build takes them once, the first time it runs this with its own
    /// Notifications switch on (taking them with it off would leave neither build notifying).
    static func claimIfRelease(_ own: UserDefaults = .standard, notificationsOn: Bool) {
        guard !isDevBuild, notificationsOn, !own.bool(forKey: claimedKey) else { return }
        own.set(true, forKey: claimedKey)
        claim()
    }

    private static let devicesKey = "bergr.push.devices"

    /// This build's id on the machines' helpers (see `PushRegistration.deviceID`), so the other
    /// build can take this one off them when it takes notifications.
    static func publish(deviceID: String) {
        guard let group else { return }
        var all = group.dictionary(forKey: devicesKey) as? [String: String] ?? [:]
        if all[me] != deviceID { all[me] = deviceID; group.set(all, forKey: devicesKey) }
    }

    /// The other builds' ids on the helpers: removed from them when this build registers.
    static var otherDeviceIDs: [String] {
        let all = group?.dictionary(forKey: devicesKey) as? [String: String] ?? [:]
        return all.filter { $0.key != me }.map(\.value).sorted()
    }

    /// "the TestFlight build" for Settings.
    static var ownerName: String {
        guard let owner else { return "another Bergr" }
        return owner.hasSuffix(".dev") ? "the dev build" : "the TestFlight or App Store build"
    }
}
