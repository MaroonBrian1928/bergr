// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation
import Network
import HerdrKit
import Observation
import NIOCore

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

    enum Intent: Equatable { case stopped, running, paused }

    /// What the user wants: `stopped` until started, `paused` while the app is in the background.
    private(set) var intent: Intent = .stopped
    /// The current start or retry. It owns the SSH line and the client; nothing else does.
    private var attempt: ConnectionAttempt?
    private var generation: UInt64 = 0
    /// Changes for every successful connection, even when SwiftUI coalesces a drop/reconnect.
    private(set) var connectionRevision: UInt64 = 0
    /// Kept for the session so reconnects do not ask for Face ID again.
    private var signingKey: SigningKey?
    private let knownHosts: any KnownHostsStore
    private let connector: HostConnector
    private let timing: ConnectionTiming

    /// Terminals on screen now (the terminal screen, a peek), counted: both can show one at once.
    private var looking: [String: Int] = [:]
    /// The turn `herdr.seen` was written for while on screen: once per turn, so a "mark unread"
    /// from another client isn't overruled by a screen nobody watches.
    private var seenWritten: [String: UInt64] = [:]

    init(
        host: Host, knownHosts: any KnownHostsStore = UserDefaultsKnownHosts(),
        connector: HostConnector? = nil, timing: ConnectionTiming = .init()
    ) {
        self.host = host
        self.knownHosts = knownHosts
        self.connector = connector ?? .live(host: host, knownHosts: knownHosts)
        self.timing = timing
    }

    /// When herdr-core was last heard from on the current or last line (for "last update … ago").
    private(set) var lastHeardAt: Date?

    var isActive: Bool { attempt != nil }

    private var client: HerdrClient? { attempt?.connection?.client }

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

    func exec(_ argv: [String], on machine: String? = nil, timeout: Double? = nil) async throws -> ExecOutput {
        try await connectedClient().exec(argv: argv, on: machine, timeout: timeout)
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
    #if os(macOS)
    @ObservationIgnored private var inputQueues: [String: TerminalInputQueue] = [:]

    func automate(address: String, _ steps: @escaping @MainActor () async -> Void) async {
        let queue = inputQueues[address] ?? TerminalInputQueue()
        inputQueues[address] = queue
        await queue.run(steps)
    }
    #endif

    // MARK: Chat feeds

    /// Conversations being followed, by terminal address. The session owns them, not the screen:
    /// a screen can disappear for a moment during navigation, and that mustn't end the feed.
    @ObservationIgnored private var feeds: [String: (agent: ChatAgent, feed: ChatFeed, task: Task<Void, Never>, used: Date)] = [:]
    /// Feeds whose line went away (the app went to the background): kept, not their tasks, so
    /// coming back follows the conversation into the same feed. The chat keeps showing what it
    /// had while the conversation is read again, instead of going blank and rebuilding.
    @ObservationIgnored private var pausedFeeds: [String: (agent: ChatAgent, feed: ChatFeed, start: FeedStart, used: Date)] = [:]
    /// What a feed was started with, so the session can start it again by itself.
    struct FeedStart { let pid: Int32; let cwd: String; let sessionHint: String? }
    @ObservationIgnored private var feedStarts: [String: FeedStart] = [:]
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
        let paused = pausedFeeds.removeValue(forKey: address)
        let feed = paused?.agent == agent ? paused!.feed : ChatFeed()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            if self.host.isDemo { await feed.runDemo(agent: agent, cwd: cwd); return }
            await feed.run(session: self, agent: agent, pid: pid, cwd: cwd, sessionHint: sessionHint)
        }
        feeds[address] = (agent, feed, task, .now)
        feedStarts[address] = FeedStart(pid: pid, cwd: cwd, sessionHint: sessionHint)
        return feed
    }

    /// Back on the line: follow again the conversations that were open when it went away. Done
    /// here, not by the screens: a chat on screen while the app was in the background never saw the
    /// line drop and come back (no redraws in the background), so it never asked again, and the chat
    /// stayed frozen until you left it and came back.
    @MainActor
    private func resumeFeeds() {
        // Most recently used first, and only into free places: resuming must never evict a feed
        // a chat on screen just asked for (it would keep showing a stopped feed until reopened).
        for (address, paused) in pausedFeeds.sorted(by: { $0.value.used > $1.value.used }) {
            guard feeds[address] == nil else { pausedFeeds[address] = nil; continue }
            guard feeds.count < Self.maxFeeds else { break }
            _ = chatFeed(address: address, agent: paused.agent, pid: paused.start.pid,
                         cwd: paused.start.cwd, sessionHint: paused.start.sessionHint)
        }
    }

    /// Sub-agents running under a terminal's agent, from its chat feed if one is being followed.
    @MainActor
    func runningSubagents(address: String) -> Int {
        feeds[address]?.feed.runningSubagents ?? 0
    }

    private func stopFeeds() {
        for (address, entry) in feeds {
            entry.task.cancel()
            if let start = feedStarts[address] { pausedFeeds[address] = (entry.agent, entry.feed, start, entry.used) }
        }
        feeds = [:]
    }

    /// Whether a command can run on this machine over SSH (not the demo).
    var canRunCommands: Bool { (attempt?.connection?.ssh != nil || attempt?.connection?.isLocal == true) && !host.isDemo }
    var isWindowsHost: Bool { attempt?.connection?.isWindows == true }

    /// Runs a long-lived command on the machine, beside herdr-core (the chat feed).
    func openExec(_ command: String) async throws -> ExecPipe {
        guard state == .connected else { throw SessionError.connectionLost }
        if attempt?.connection?.isLocal == true { return try LocalCore.openExec(command) }
        guard let ssh = attempt?.connection?.ssh else { throw SessionError.connectionLost }
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
        keyLibrary = keys
        guard attempt == nil else { return }
        intent = .running
        generation += 1
        let generation = generation
        let context = HostConnector.Context(
            reconnecting: snapshot != nil,
            progress: { _ in },
            signingKey: { [weak self] in
                guard let self else { throw CancellationError() }
                guard let info = keys.key(id: self.host.keyID) else { throw SessionError.noKey }
                if let key = self.signingKey { return key }
                let key = try await keys.signingKey(for: info)
                // A replaced attempt's unlock is still good, but only the current one may keep it.
                if self.generation == generation, self.attempt != nil { self.signingKey = key }
                return key
            },
            askToTrust: { [weak self] offered in await self?.askToTrust(offered) ?? false })
        let attempt = ConnectionAttempt(
            generation: generation, owner: self, connector: connector, context: context,
            isRetryable: Self.isRetryable, timing: timing)
        self.attempt = attempt
        attempt.start()
    }

    /// `forgetKey: false` keeps the unlocked key, so resuming from the background skips Face ID.
    func stop(forgetKey: Bool = true) {
        intent = .stopped
        stopFeeds()
        // The attempt takes and closes what it holds now: a teardown that ran later would close
        // the connection a retry has opened in the meantime.
        attempt?.cancel()
        attempt = nil
        if forgetKey { signingKey = nil }
        answerHostKey(trust: false)
        if case .failed = state {} else { state = .idle }
    }

    func retry(keys: KeyLibrary) {
        stop()
        start(keys: keys)
    }

    /// The app went to the background. Pausing twice, or a session nobody started, changes nothing.
    func pause() {
        guard intent == .running, isActive else { return }
        stop(forgetKey: false)
        intent = .paused
    }

    func resume(keys: KeyLibrary) {
        guard intent == .paused else { return }
        start(keys: keys)
    }

    /// A background connection can look live after iOS suspended its sockets. Replace it on
    /// return, preserving the unlocked key and chat feeds, rather than waiting for navigation.
    /// Checks the line now (the network just changed): no answer from herdr-core within 3 s means
    /// it's gone, so reconnect at once instead of waiting out the 40 s silence limit. herdr-core's
    /// heartbeat comes every 15 s, so silence alone can't be judged any faster than that.
    func probe(keys: KeyLibrary) {
        // Waiting out a backoff and the network is back: don't sleep up to 30 s more.
        if case .failed(_, retrying: true) = state { attempt?.retryNow(); return }
        guard state == .connected, !probing, let client = try? connectedClient() else { return }
        probing = true
        lastProbe = .now
        let attempt = self.attempt
        Task { @MainActor in
            defer { probing = false }
            let known = await client.roundTrip
            let limit = known.map { max(Duration.seconds(3), $0.timeout * 2) } ?? .seconds(3)
            let alive = await Deadline.answers(within: limit) { _ = try await client.listTerminals() }
            roundTrip = await client.roundTrip
            // Still the same line, and it didn't answer: replace it.
            guard !alive, self.attempt === attempt, state == .connected else { return }
            retry(keys: keys)
        }
    }

    @ObservationIgnored private var probing = false
    @ObservationIgnored private var lastProbe: ContinuousClock.Instant?
    @ObservationIgnored private var keyLibrary: KeyLibrary?

    /// While a chat or terminal is on screen and the app active: check the line every 3 s, like
    /// Mosh. A line that dies without a network change (tunnel, host asleep, VPN) otherwise looks
    /// live until herdr-core's 40 s silence limit, and takes keys meanwhile.
    /// Twice as slow on cellular, Low Power Mode or Low Data Mode: every check wakes the radio.
    nonisolated static func checkInterval(expensive: Bool) -> Duration { .seconds(expensive ? 6 : 3) }

    func keepChecking() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.checkInterval(expensive: NetworkWatcher.shared.isExpensive))
            guard !Task.isCancelled else { return }
            checkLine()
        }
    }

    /// Checks the line unless it was checked moments ago (several screens may ask) or the core
    /// sent something within the last 3 s: output already proves the line, so a busy screen costs
    /// no extra traffic and the phone's radio can rest between checks only on a quiet one.
    func checkLine() {
        guard let keys = keyLibrary, let client = try? connectedClient() else { return }
        if let lastProbe, ContinuousClock.now - lastProbe < .milliseconds(2500) { return }
        Task { @MainActor in
            if ContinuousClock.now - (await client.lastReceived) < .seconds(3) { return }
            probe(keys: keys)
        }
    }

    /// The line's smoothed round trip as of the last probe; nil until a call has been answered.
    private(set) var roundTrip: RoundTrip?

    func resumeAfterBackground(keys: KeyLibrary) {
        if intent == .paused {
            start(keys: keys)
        } else if intent == .running, isActive {
            stop(forgetKey: false)
            start(keys: keys)
        }
    }

    /// The snapshot after one message, or nil when it changes nothing the screens show. Every
    /// write to the observed `snapshot` redraws each reader of `terminals`, so only a change is
    /// written. An event that leaves the terminals as they were keeps its `seq` out of the
    /// observed value: the stream is in order, and a `missed` always replaces the snapshot.
    static func snapshot(after message: EventMessage, from current: TerminalSnapshot) -> TerminalSnapshot? {
        if case .heartbeat = message { return nil }
        var next = current
        next.apply(message)
        if case .missed = message { return next }
        return next.terminals == current.terminals ? nil : next
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
    static func isRetryable(_ error: Error) -> Bool {
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
        if let channel = error as? ChannelError {
            switch channel {
            case .connectTimeout:
                return "SSH timed out connecting or signing in to \(name). Check the address, SSH server and selected key, then tap Retry."
            case .ioOnClosedChannel, .alreadyClosed, .eof, .inputClosed, .outputClosed:
                return "The SSH connection to \(name) closed before the operation finished. Tap Retry."
            default:
                return "SSH failed for \(name): \(String(describing: channel))"
            }
        }
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

extension HostSession: ConnectionAttemptOwner {
    func isCurrent(_ a: ConnectionAttempt) -> Bool { attempt === a }

    func attempt(_ a: ConnectionAttempt, progress: String) {
        guard isCurrent(a) else { return }
        state = .connecting(progress)
    }

    func attempt(_ a: ConnectionAttempt, machines: [MachineView]) {
        guard isCurrent(a) else { return }
        self.machines = machines
    }

    func attempt(_ a: ConnectionAttempt, layout: HerdrAppLayout?) {
        guard isCurrent(a) else { return }
        self.layout = layout
    }

    func attempt(_ a: ConnectionAttempt, connected c: HostConnection, snapshot: TerminalSnapshot) {
        guard isCurrent(a) else { return }
        self.snapshot = snapshot
        coreName = c.coreName
        coreVersion = c.coreVersion
        connectionRevision &+= 1
        state = .connected
        markLookedAt()
        resumeFeeds()
    }

    func attempt(_ a: ConnectionAttempt, received message: EventMessage) async {
        guard isCurrent(a) else { return }
        // Coarse: it's only shown as "… ago", and each write redraws whoever shows it.
        if lastHeardAt.map({ Date.now.timeIntervalSince($0) > 5 }) ?? true { lastHeardAt = .now }
        if let current = snapshot, let next = Self.snapshot(after: message, from: current) { snapshot = next }
        markLookedAt()
        guard let client = a.connection?.client else { return }
        switch message {
        case .missed:
            // Documents are not in snapshots: read them again.
            let read = try? await client.listTerminals().machines
            guard isCurrent(a) else { return }
            if let read { machines = read }
            let doc = try? await client.herdrAppLayout()
            guard isCurrent(a) else { return }
            if let doc { layout = doc }
        case .event(let event):
            if case .doc(let name) = event.change, name == HerdrAppLayout.documentName {
                let doc = try? await client.herdrAppLayout()
                guard isCurrent(a) else { return }
                if let doc { layout = doc }
            }
        case .heartbeat:
            break
        }
    }

    func attempt(_ a: ConnectionAttempt, failed error: Error, retrying: Bool) {
        guard isCurrent(a) else { return }
        stopFeeds()
        state = .failed(Self.describe(error, host: host), retrying: retrying)
    }

    func attemptFinished(_ a: ConnectionAttempt) {
        guard isCurrent(a) else { return }
        attempt = nil
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
        for session in sessions.values { session.pause() }
    }

    func resumePaused(keys: KeyLibrary) {
        for session in sessions.values { session.resume(keys: keys) }
    }

    func resumeAfterBackground(keys: KeyLibrary) {
        for session in sessions.values { session.resumeAfterBackground(keys: keys) }
    }

    /// The network changed: every connected machine checks its line now.
    func probeAll(keys: KeyLibrary) {
        for session in sessions.values { session.probe(keys: keys) }
    }
}
