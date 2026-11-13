import HerdrKit
import Observation
import SwiftUI

/// Gets a machine a core links to ready to add directly: user, reachable address, key allowed in.
extension LinkedSetup {
    @MainActor
    static func prepareHost(
        name: String, host: String?, target: String?, parent: HostSession, keys: KeyLibrary
    ) async -> Host {
        let line = keys.key(id: parent.host.keyID)?.authorizedKeysLine
        let found = await run(on: name, keyLine: line, session: parent)
        let address = address(target: target, found: found?.address) ?? host ?? name
        return Host(name: name,
                    target: SSHTarget(host: address, username: found?.user ?? parent.host.target.username),
                    keyID: parent.host.keyID, systemSSH: parent.host.systemSSH)
    }
}

/// Moves the machines a core reaches through its link to their own saved connection, one at a
/// time: each is prepared, tested with a temporary session, and saved only when that connects.
@MainActor @Observable
final class DirectMigration {
    struct Candidate: Identifiable, Equatable {
        let name: String
        let host: String?
        let target: String?
        let parentID: UUID
        let parentName: String
        var id: String { "\(parentID.uuidString)/\(name)" }
        var names: [String] { [name, host, target].compactMap { $0?.lowercased() } }
    }

    enum Result: Equatable {
        case connected
        case stayed(String)
    }

    struct Outcome: Identifiable, Equatable {
        let candidate: Candidate
        let result: Result
        var id: String { candidate.id }
    }

    /// A machine and the machines its core links to.
    struct Parent {
        let host: Host
        let connected: Bool
        let machines: [MachineView]
    }

    typealias Prepare = @MainActor (Candidate) async -> Host
    /// nil: connected. Otherwise why not. `watch` reports the temporary session (host-key prompt).
    typealias Test = @MainActor (Host, _ watch: @MainActor (HostSession?) -> Void) async -> String?

    private(set) var outcomes: [Outcome] = []
    private(set) var current: Candidate?
    private(set) var position = 0
    private(set) var total = 0
    private(set) var running = false
    private(set) var finished = false
    /// The temporary session under test, so the sheet can ask about its host key.
    private(set) var testing: HostSession?

    private let store: HostStore
    private let prepare: Prepare
    private let test: Test

    init(store: HostStore, prepare: @escaping Prepare, test: @escaping Test) {
        self.store = store
        self.prepare = prepare
        self.test = test
    }

    // MARK: Which machines

    /// Linked machines of connected, non-demo machines that have no saved connection of their own.
    static func candidates(hosts: [Host], parents: [Parent]) -> [Candidate] {
        var result: [Candidate] = []
        for parent in parents where parent.connected && !parent.host.isDemo {
            for machine in parent.machines {
                let candidate = Candidate(name: machine.name, host: machine.host, target: machine.target,
                                          parentID: parent.host.id, parentName: parent.host.name)
                if hasDirectHost(candidate, in: hosts) { continue }
                // The same machine linked from two cores is offered once.
                if result.contains(where: { !Set($0.names).isDisjoint(with: candidate.names) }) { continue }
                result.append(candidate)
            }
        }
        return result
    }

    static func hasDirectHost(_ candidate: Candidate, in hosts: [Host]) -> Bool {
        hosts.contains { other in
            other.id != candidate.parentID
                && (candidate.names.contains(other.name.lowercased())
                    || candidate.names.contains(other.target.host.lowercased()))
        }
    }

    static func candidates(store: HostStore, sessions: SessionStore) -> [Candidate] {
        candidates(hosts: store.hosts, parents: store.hosts.map { host in
            let session = sessions.existing(host.id)
            return Parent(host: host, connected: session?.state == .connected, machines: session?.machines ?? [])
        })
    }

    // MARK: Banner

    /// Identifies the set of machines the banner is about; dismissing hides it until this changes.
    static func bannerKey(_ candidates: [Candidate]) -> String {
        candidates.map(\.id).sorted().joined(separator: ",")
    }

    static func showBanner(_ candidates: [Candidate], dismissedKey: String?) -> Bool {
        !candidates.isEmpty && bannerKey(candidates) != dismissedKey
    }

    // MARK: Running

    func run(_ candidates: [Candidate]) async {
        guard !running else { return }
        running = true
        finished = false
        outcomes = []
        total = candidates.count
        position = 0
        defer { current = nil; testing = nil; running = false; finished = true }
        for candidate in candidates {
            position += 1
            // An earlier machine in this run may have become the direct host for this one.
            if Self.hasDirectHost(candidate, in: store.hosts) { continue }
            current = candidate
            let host = await prepare(candidate)
            if let reason = await test(host, { [self] in testing = $0 }) {
                outcomes.append(Outcome(candidate: candidate, result: .stayed(reason)))
            } else {
                saveAfterParent(host, parentID: candidate.parentID)
                outcomes.append(Outcome(candidate: candidate, result: .connected))
            }
            testing = nil
        }
    }

    private func saveAfterParent(_ host: Host, parentID: UUID) {
        store.save(host)
        guard let from = store.hosts.firstIndex(where: { $0.id == host.id }),
              let parent = store.hosts.firstIndex(where: { $0.id == parentID }), from != parent + 1 else { return }
        store.move(fromOffsets: IndexSet(integer: from), toOffset: from < parent ? parent : parent + 1)
    }

    // MARK: Live

    static func live(store: HostStore, sessions: SessionStore, keys: KeyLibrary) -> DirectMigration {
        DirectMigration(
            store: store,
            prepare: { candidate in
                let parentHost = store.hosts.first { $0.id == candidate.parentID }!
                return await LinkedSetup.prepareHost(
                    name: candidate.name, host: candidate.host, target: candidate.target,
                    parent: sessions.session(for: parentHost), keys: keys)
            },
            test: { host, watch in await liveTest(host, keys: keys, watch: watch) })
    }

    /// Starts a temporary session for `host`, waits for it to connect, stops it. The time spent
    /// waiting for a host-key decision does not count toward the timeout.
    static func liveTest(
        _ host: Host, keys: KeyLibrary, timeout: Double = 20, watch: @MainActor (HostSession?) -> Void
    ) async -> String? {
        let session = HostSession(host: host)
        watch(session)
        session.start(keys: keys)
        defer { session.stop(); watch(nil) }
        var waited = 0.0
        while waited < timeout {
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return "Cancelled" }
            if session.pendingHostKey != nil { continue }
            switch session.state {
            case .connected: return nil
            case .failed(let reason, _): return reason
            default: waited += 0.2
            }
        }
        return "No answer within \(Int(timeout)) seconds"
    }
}

/// Runs the migration and shows each machine's result.
struct DirectMigrationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: DirectMigration
    private let store: HostStore
    private let sessions: SessionStore
    @State private var started = false

    init(store: HostStore, sessions: SessionStore, keys: KeyLibrary) {
        self.store = store
        self.sessions = sessions
        _model = State(initialValue: .live(store: store, sessions: sessions, keys: keys))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let offered = model.testing?.pendingHostKey {
                    Section("Trust this machine?") {
                        Text("This is the first time Bergr connects to \(offered.host). Check that this fingerprint matches the machine.")
                            .font(.subheadline)
                        Text(offered.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                        HStack {
                            Button("Trust") { model.testing?.answerHostKey(trust: true) }.buttonStyle(.borderedProminent)
                            Button("Don't Trust", role: .destructive) { model.testing?.answerHostKey(trust: false) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if let current = model.current {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Connecting to \(current.name) (\(model.position) of \(model.total))…")
                        }
                    }
                }
                if !model.outcomes.isEmpty {
                    Section("Results") {
                        ForEach(model.outcomes) { outcome in row(outcome) }
                    }
                } else if model.finished {
                    Section { Text("No linked machines need a direct connection.").foregroundStyle(.secondary) }
                }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Connect Directly")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(model.running)
                }
                if model.finished, model.outcomes.contains(where: { $0.result != .connected }) {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Try Again") { Task { await start() } }
                    }
                }
            }
            .interactiveDismissDisabled(model.running)
            .task {
                guard !started else { return }
                started = true
                await start()
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 360)
        #endif
    }

    private func start() async {
        await model.run(DirectMigration.candidates(store: store, sessions: sessions))
    }

    @ViewBuilder
    private func row(_ outcome: DirectMigration.Outcome) -> some View {
        switch outcome.result {
        case .connected:
            Label("\(outcome.candidate.name): Connected directly", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .stayed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("\(outcome.candidate.name): Stayed via \(outcome.candidate.parentName)",
                      systemImage: "arrow.triangle.branch")
                Text(reason).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}
