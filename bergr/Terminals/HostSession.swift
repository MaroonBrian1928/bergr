// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation
import Network
import HerdrKit
import Observation

/// One machine's connection: SSH, herdr-core, and a live terminal snapshot kept
/// current by the event stream. Reconnects on its own after a dropped line.
@Observable
final class HostSession {
    enum State: Equatable {
        case idle
        case connecting(String)
        case connected
        /// `retrying`: a reconnect is scheduled; otherwise the user must act (Retry).
        case failed(String, retrying: Bool)
    }

    let host: Host
    private(set) var state: State = .idle
    private(set) var snapshot: TerminalSnapshot?
    private(set) var machines: [MachineView] = []
    /// herdr-app's spaces and tabs on this machine, when herdr-app is used there.
    private(set) var layout: HerdrAppLayout?
    private(set) var coreName: String?
    private(set) var coreVersion: String?

    /// Set while the user must decide whether to trust an unknown host key.
    private(set) var pendingHostKey: HostKey?
    /// A terminal to open watching this once (the list's "Watch"), whatever the eye button
    /// remembers; the terminal screen takes it when it opens it.
    var watchNext: String?
    private var hostKeyDecision: CheckedContinuation<Bool, Never>?

    private var runner: Task<Void, Never>?
    private var ssh: SSHConnection?
    private var client: HerdrClient?
    /// Kept for the session so reconnects do not ask for Face ID again.
    private var signingKey: SigningKey?
    private var lastHeard = Date.distantPast
    private let knownHosts: any KnownHostsStore

    /// Terminals on screen now (the terminal screen, a peek), counted: both can show one at once.
    private var looking: [String: Int] = [:]
    /// The turn `herdr.seen` was written for while on screen: once per turn, so a "mark unread"
    /// from another client isn't overruled by a screen nobody watches.
    private var seenWritten: [String: UInt64] = [:]

    /// herdr-core sends a heartbeat every 15 s; this much silence means the line is dead.
    private static let silenceLimit: TimeInterval = 40

    init(host: Host, knownHosts: any KnownHostsStore = UserDefaultsKnownHosts()) {
        self.host = host
        self.knownHosts = knownHosts
    }

    var isActive: Bool { runner != nil }

    var terminals: [Terminal] { snapshot?.terminals ?? [] }

    /// Live terminals whose program is waiting for a person.
    var needsYouCount: Int {
        terminals.filter { $0.isLive && ($0.status?.state == "blocked" || $0.status?.state == "error") }.count
    }

    func terminal(_ address: String?) -> Terminal? {
        address.flatMap { snapshot?[$0] }
    }

    /// Attaches to a terminal's screen on the current connection, with up to `history` lines of
    /// what scrolled off before. Observing watches it at the size another viewer set, without typing.
    func attach(
        address: String, cols: Int, rows: Int, history: Int = 0, observe: Bool = false, display: DisplayFacts?
    ) async throws -> AttachedTerminal {
        guard let client, state == .connected else { throw SessionError.connectionLost }
        return try await client.attach(
            terminal: address, cols: cols, rows: rows, history: history, observe: observe, display: display)
    }

    // MARK: Managing terminals

    private func connectedClient() throws -> HerdrClient {
        guard let client, state == .connected else { throw SessionError.connectionLost }
        return client
    }

    func run(_ request: RunRequest) async throws -> Terminal {
        try await connectedClient().run(request)
    }

    func templates() async -> [TemplateInfo] {
        (try? await connectedClient().templates()) ?? []
    }

    func label(_ address: String, _ labels: [String: String]) async throws {
        try await connectedClient().label(address, labels)
    }

    func kill(_ address: String) async throws {
        try await connectedClient().kill(address)
    }

    func remove(_ address: String) async throws {
        try await connectedClient().remove(address)
    }

    // MARK: Read state

    /// Someone is looking at this terminal (the app is in front: in the background, sessions
    /// are paused). Marks its agent read, now and after each turn while it stays on screen.
    func startLooking(at address: String) {
        looking[address, default: 0] += 1
        markLookedAt()
    }

    func stopLooking(at address: String) {
        looking[address, default: 0] -= 1
        guard looking[address, default: 0] <= 0 else { return }
        looking.removeValue(forKey: address)
        // Looking again later raises it again.
        seenWritten.removeValue(forKey: address)
    }

    /// Raises `herdr.seen` on the agents on screen (herdr-app's `docs/labels.md`). Called when
    /// one comes on screen and after every event, which covers the `turn` event that ends a turn.
    private func markLookedAt() {
        guard state == .connected, let client else { return }
        for address in looking.keys {
            guard let terminal = terminal(address), terminal.isLive, terminal.status != nil,
                  let labels = terminal.markSeen, let turn = terminal.turn, seenWritten[address] != turn
            else { continue }
            seenWritten[address] = turn
            Task { try? await client.label(address, labels) }
        }
    }

    /// The user's home folder there, guessed from where terminals run (`/Users/me`, `/home/me`).
    // MARK: Chat feeds

    /// Conversations being followed, by terminal address. The session owns them, not the screen:
    /// a screen can disappear for a moment during navigation, and that mustn't end the feed.
    @ObservationIgnored private var feeds: [String: (agent: ChatAgent, feed: ChatFeed, task: Task<Void, Never>, used: Date)] = [:]
    /// Each feed is an SSH channel (sshd allows 10 per connection by default; herdr-core uses one).
    private static let maxFeeds = 4

    /// The feed for a terminal's agent: the running one, or a new one.
    @MainActor
    func chatFeed(address: String, agent: ChatAgent, pid: Int32, cwd: String, sessionHint: String?) -> ChatFeed {
        if let entry = feeds[address], entry.agent == agent {
            feeds[address]?.used = .now
            return entry.feed
        }
        feeds.removeValue(forKey: address)?.task.cancel()
        while feeds.count >= Self.maxFeeds, let oldest = feeds.min(by: { $0.value.used < $1.value.used })?.key {
            feeds.removeValue(forKey: oldest)?.task.cancel()
        }
        let feed = ChatFeed()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.host.isDemo { await feed.runDemo(agent: agent, cwd: cwd); return }
            await feed.run(session: self, agent: agent, pid: pid, cwd: cwd, sessionHint: sessionHint)
        }
        feeds[address] = (agent, feed, task, .now)
        return feed
    }

    /// Sub-agents running under a terminal's agent, from its chat feed if one is being followed.
    @MainActor
    func runningSubagents(address: String) -> Int {
        feeds[address]?.feed.runningSubagents ?? 0
    }

    private func stopFeeds() {
        for entry in feeds.values { entry.task.cancel() }
        feeds = [:]
    }

    /// Whether a command can run on this machine over SSH (not the demo).
    var canRunCommands: Bool { ssh != nil && !host.isDemo }

    /// Runs a long-lived command on the machine, beside herdr-core (the chat feed).
    func openExec(_ command: String) async throws -> ExecPipe {
        guard let ssh, state == .connected else { throw SessionError.connectionLost }
        return try await ssh.openExec(command)
    }

    var homeFolder: String? {
        for terminal in terminals {
            let parts = terminal.cwd.split(separator: "/")
            if parts.count >= 2, ["Users", "home"].contains(parts[0]) { return "/\(parts[0])/\(parts[1])" }
        }
        return nil
    }

    // MARK: Lifecycle

    /// Connects and keeps the connection up until `stop()`.
    func start(keys: KeyLibrary) {
        guard runner == nil else { return }
        runner = Task { await run(keys: keys) }
    }

    /// `forgetKey: false` keeps the unlocked key, so resuming from the background skips Face ID.
    func stop(forgetKey: Bool = true) {
        stopFeeds()
        runner?.cancel()
        runner = nil
        if forgetKey { signingKey = nil }
        answerHostKey(trust: false)
        Task { await teardown() }
        if case .failed = state {} else { state = .idle }
    }

    func retry(keys: KeyLibrary) {
        stop()
        start(keys: keys)
    }

    private func run(keys: KeyLibrary) async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            do {
                try await connectOnce(keys: keys)
                delay = .seconds(1)
                try await followEvents()
                throw SessionError.connectionLost
            } catch is CancellationError {
                break
            } catch {
                await teardown()
                if Task.isCancelled { break }
                let retrying = Self.isRetryable(error)
                state = .failed(Self.describe(error, host: host), retrying: retrying)
                guard retrying else { break }
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
        if !Task.isCancelled { runner = nil }
    }

    private func connectOnce(keys: KeyLibrary) async throws {
        if host.isDemo {
            state = .connecting("Starting the demo…")
            let client = try await HerdrClient.connectDemo()
            self.client = client
            coreName = "Demo"
            coreVersion = await client.hello?.version
            return
        }
        guard let keyInfo = keys.key(id: host.keyID) else { throw SessionError.noKey }
        if signingKey == nil {
            state = .connecting("Unlocking key…")
            signingKey = try await keys.signingKey(for: keyInfo)
        }
        state = .connecting(snapshot == nil ? "Connecting to \(host.target.host)…" : "Reconnecting…")
        let ssh = try await SSHConnection.connect(
            to: host.target, key: signingKey!, knownHosts: knownHosts,
            onUnknownHost: { [weak self] offered in
                await self?.askToTrust(offered) ?? false
            })
        self.ssh = ssh

        state = .connecting("Starting herdr-core…")
        let client = try await HerdrClient.connect(ssh: ssh, session: host.session)
        self.client = client
        let hello = await client.hello
        coreName = hello?.core.name
        coreVersion = hello?.version
    }

    /// Applies events until the stream ends, errors, or goes quiet.
    private func followEvents() async throws {
        guard let client else { throw SessionError.connectionLost }
        // Subscribe first, then read anything else, as the protocol asks.
        let subscription = try await client.subscribeEvents()
        snapshot = subscription.snapshot
        machines = (try? await client.listTerminals().machines) ?? []
        layout = try? await client.herdrAppLayout()
        lastHeard = .now
        state = .connected
        markLookedAt()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in subscription.messages {
                    await self.apply(message)
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    if await self.silentTooLong() { throw SessionError.timedOut }
                }
            }
            // The first child to finish (stream ended, error, silence) ends both.
            try await group.next()
            group.cancelAll()
        }
    }

    private func apply(_ message: EventMessage) async {
        lastHeard = .now
        snapshot?.apply(message)
        markLookedAt()
        guard let client else { return }
        switch message {
        case .missed:
            // Documents are not in snapshots: read them again.
            machines = (try? await client.listTerminals().machines) ?? machines
            layout = (try? await client.herdrAppLayout()) ?? layout
        case .event(let event):
            if case .doc(let name) = event.change, name == HerdrAppLayout.documentName {
                layout = (try? await client.herdrAppLayout()) ?? layout
            }
        case .heartbeat:
            break
        }
    }

    private func silentTooLong() -> Bool {
        Date.now.timeIntervalSince(lastHeard) > Self.silenceLimit
    }

    private func teardown() async {
        let (client, ssh) = (self.client, self.ssh)
        self.client = nil
        self.ssh = nil
        await client?.close()
        await ssh?.close()
    }

    /// Forget the stored host key, e.g. after a server was reinstalled.
    func forgetHostKey() {
        knownHosts.removeHostKey(for: host.target.knownHostsName)
    }

    // MARK: Host key trust

    private func askToTrust(_ offered: HostKey) async -> Bool {
        await withCheckedContinuation { continuation in
            hostKeyDecision = continuation
            pendingHostKey = offered
        }
    }

    func answerHostKey(trust: Bool) {
        pendingHostKey = nil
        hostKeyDecision?.resume(returning: trust)
        hostKeyDecision = nil
    }

    // MARK: Errors

    /// Network trouble is retried; problems a person must fix are not.
    private static func isRetryable(_ error: Error) -> Bool {
        switch error {
        case is SessionError: return error as? SessionError != .noKey
        case SSHTransportError.commandFailed, SSHTransportError.authenticationFailed,
             SSHTransportError.hostKeyChanged, SSHTransportError.hostKeyRejected:
            return false
        case HerdrError.rpc, HerdrError.invalidResponse: return false
        default:
            // Face ID cancelled, key missing, ... come from LocalAuthentication / CryptoKit.
            let domain = (error as NSError).domain
            return domain != "com.apple.LocalAuthentication" && domain != "CryptoTokenKit"
        }
    }

    /// What went wrong, and what to do about it, in words: not "NIOCore.IOError error 1".
    static func describe(_ error: Error, host: Host) -> String {
        let name = host.name.isEmpty ? host.target.host : host.name
        if case SSHTransportError.commandFailed(127, _) = error {
            return "herdr-core is not installed on this machine (looked on PATH and in ~/.local/bin). Install it there, then tap Retry."
        }
        if case SSHTransportError.authenticationFailed(let user) = error {
            return "\(name) didn't accept your key for \(user). Add the key's public line to "
                + "~/.ssh/authorized_keys there (Keys → your key → Copy)."
        }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") {
            return "\(name) didn't accept your key for \(host.target.username). Add the key's public line to "
                + "~/.ssh/authorized_keys there (Keys → your key → Copy)."
        }
        let ns = error as NSError
        if ns.domain == "com.apple.LocalAuthentication", [-2, -4, -9].contains(ns.code) {
            return "Unlocking your key was canceled. Tap Retry to unlock it."
        }
        // The Network framework (how Bergr connects on iOS) reports POSIX and DNS failures as NWError.
        if let nw = error as? NWError {
            let place = "\(host.target.host):\(host.target.port)"
            switch nw {
            case .posix(let code):
                switch code {
                case .ECONNREFUSED:
                    return "Nothing accepted SSH at \(place). Is the SSH server running there, on that port?"
                case .EPERM, .EACCES:
                    return "iOS blocked Bergr from reaching \(name). Turn on Settings → Privacy & Security → "
                        + "Local Network → Bergr, then tap Retry."
                case .ETIMEDOUT:
                    return "Timed out reaching \(name) (\(place)). Nothing answered: check it's on, and that this "
                        + "address is reachable from here (on a VPN, the address the VPN routes)."
                case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN, .EHOSTDOWN:
                    return "Can't reach \(name) (\(place)). Is it on, and on this network or your VPN?"
                case .ECONNRESET, .ECONNABORTED, .EPIPE:
                    return "\(name) closed the connection. Tap Retry."
                default: break
                }
            case .dns:
                return "Couldn't look up \(host.target.host). Check the name, or use its IP address."
            default: break
            }
        }
        if text.contains("connectTimeout") {
            return "Timed out reaching \(name) (\(host.target.host):\(host.target.port)). Nothing answered: "
                + "check it's on, and that this address is reachable from here (on a VPN, the address the VPN routes)."
        }
        // Network errors carry the system's error number: "(errno: 61)".
        if let range = text.range(of: #"errno: (\d+)"#, options: .regularExpression),
           let code = Int(text[range].dropFirst("errno: ".count)) {
            let place = "\(host.target.host):\(host.target.port)"
            switch code {
            case 1, 13:
                return "iOS blocked Bergr from reaching \(name). Turn on Settings → Privacy & Security → "
                    + "Local Network → Bergr, then tap Retry."
            case 61:
                return "Nothing accepted SSH at \(place). Is the SSH server running there, on that port?"
            case 50, 51, 60, 64, 65:
                return "Can't reach \(name) (\(place)). Is it on, and on this network or your VPN?"
            default:
                break
            }
        }
        if text.localizedCaseInsensitiveContains("nodename nor servname") || text.contains("dnsAError") {
            return "Can't find \(host.target.host). Check the address, or connect to its network or VPN."
        }
        if let error = error as? LocalizedError, let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

enum SessionError: LocalizedError, Equatable {
    case noKey
    case connectionLost
    case timedOut

    var errorDescription: String? {
        switch self {
        case .noKey: "This machine has no SSH key selected. Edit it and pick one."
        case .connectionLost: "The connection was lost. Tap Retry to reconnect."
        case .timedOut: "The machine stopped answering. Check that it is on and reachable, then tap Retry."
        }
    }
}

/// Keeps one session per machine, so switching machines does not reconnect.
@Observable
final class SessionStore {
    private var sessions: [UUID: HostSession] = [:]
    /// Sessions paused for the background, to resume when the app is back.
    private var paused: Set<UUID> = []

    func session(for host: Host) -> HostSession {
        if let session = sessions[host.id], session.host == host { return session }
        sessions[host.id]?.stop()
        let session = HostSession(host: host)
        sessions[host.id] = session
        return session
    }

    func existing(_ hostID: UUID) -> HostSession? { sessions[hostID] }

    /// The first machine waiting for a host-key decision, for the app-wide trust prompt.
    var awaitingTrust: HostSession? {
        sessions.values.sorted { $0.host.name < $1.host.name }.first { $0.pendingHostKey != nil }
    }

    /// Machines that have a session.
    var ids: [UUID] { Array(sessions.keys) }

    func remove(_ hostID: UUID) {
        sessions.removeValue(forKey: hostID)?.stop()
    }

    /// iOS suspends the app soon after it leaves the screen; close lines cleanly.
    func pauseAll() {
        paused = Set(sessions.filter { $0.value.isActive }.map(\.key))
        for id in paused { sessions[id]?.stop(forgetKey: false) }
    }

    func resumePaused(keys: KeyLibrary) {
        for id in paused { sessions[id]?.start(keys: keys) }
        paused = []
    }
}
