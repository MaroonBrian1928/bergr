import Foundation
import HerdrKit
import SSHTransport

/// What one successful connect holds, closed as a unit.
struct HostConnection {
    let client: HerdrClient
    /// nil for the demo and in tests.
    let ssh: SSHConnection?
    let coreName: String?
    let coreVersion: String?
    /// "This Mac": commands run here instead of over SSH.
    var isLocal = false
    var isWindows = false
    /// Live: `client.close()`, then `ssh?.close()`.
    let close: @Sendable () async -> Void
}

/// How to open one connection. Swapped for a fake in tests.
struct HostConnector {
    struct Context {
        /// A snapshot exists already: this is a reconnect.
        let reconnecting: Bool
        let progress: @MainActor (String) -> Void
        /// The cached key, or unlock it. Throws `SessionError.noKey`.
        let signingKey: @MainActor () async throws -> SigningKey
        let askToTrust: @Sendable (HostKey) async -> Bool
    }

    var connect: @MainActor (Context) async throws -> HostConnection

    static func live(host: Host, knownHosts: any KnownHostsStore) -> HostConnector {
        HostConnector { context in
            if host.isLocal {
                context.progress("Starting herdr-core…")
                let client = try await LocalCore.connect(session: host.session)
                let hello = await client.hello
                return HostConnection(
                    client: client, ssh: nil, coreName: hello?.core.name, coreVersion: hello?.version,
                    isLocal: true, close: { await client.close() })
            }
            if host.isDemo {
                context.progress("Starting the demo…")
                let client = try await HerdrClient.connectDemo()
                return HostConnection(
                    client: client, ssh: nil, coreName: "Demo", coreVersion: await client.hello?.version,
                    close: { await client.close() })
            }
            let ssh: SSHConnection
            #if os(macOS)
            if host.usesSystemSSH {
                context.progress("Connecting using this Mac's SSH…")
                ssh = SSHConnection.system(to: host.target)
            } else {
                context.progress("Unlocking key…")
                let key = try await context.signingKey()
                context.progress(context.reconnecting ? "Reconnecting…" : "Connecting to \(host.target.host)…")
                ssh = try await SSHConnection.connect(
                    to: host.target, key: key, knownHosts: knownHosts, onUnknownHost: context.askToTrust)
            }
            #else
            context.progress("Unlocking key…")
            let key = try await context.signingKey()
            context.progress(context.reconnecting ? "Reconnecting…" : "Connecting to \(host.target.host)…")
            ssh = try await SSHConnection.connect(
                to: host.target, key: key, knownHosts: knownHosts, onUnknownHost: context.askToTrust)
            #endif
            context.progress("Starting herdr-core…")
            let client: HerdrClient
            do {
                client = try await HerdrClient.connect(ssh: ssh, session: host.session)
            } catch {
                await ssh.close()
                throw error
            }
            let hello = await client.hello
            return HostConnection(
                client: client, ssh: ssh, coreName: hello?.core.name, coreVersion: hello?.version,
                isWindows: await client.platform == .windows,
                close: {
                    await client.close()
                    await ssh.close()
                })
        }
    }
}

struct ConnectionTiming {
    var firstDelay: Duration = .seconds(1)
    var maxDelay: Duration = .seconds(30)
    /// herdr-core sends a heartbeat every 15 s; this much silence means the line is dead.
    var silenceLimit: Duration = .seconds(40)
    var silenceCheck: Duration = .seconds(5)
}

@MainActor
protocol ConnectionAttemptOwner: AnyObject {
    func isCurrent(_ attempt: ConnectionAttempt) -> Bool
    func attempt(_ a: ConnectionAttempt, progress: String)
    func attempt(_ a: ConnectionAttempt, connected c: HostConnection, snapshot: TerminalSnapshot)
    /// The machines and herdr-app layout, read after `connected` (they can arrive in either order).
    func attempt(_ a: ConnectionAttempt, machines: [MachineView])
    func attempt(_ a: ConnectionAttempt, layout: HerdrAppLayout?)
    func attempt(_ a: ConnectionAttempt, received message: EventMessage) async
    func attempt(_ a: ConnectionAttempt, failed error: Error, retrying: Bool)
    /// The loop ended without being cancelled (a non-retryable failure).
    func attemptFinished(_ a: ConnectionAttempt)
}

/// One start or retry: its SSH line, its client, and the reconnect rounds that follow a drop.
/// It publishes to its owner only while the owner says it is current, and `cancel()` takes and
/// closes whatever it holds right away, so a newer attempt never shares or loses a line.
@MainActor
final class ConnectionAttempt {
    enum Phase: Equatable { case connecting, live, backingOff, cancelled, finished }

    let generation: UInt64
    private(set) var phase: Phase = .connecting
    private(set) var connection: HostConnection?

    private weak var owner: (any ConnectionAttemptOwner)?
    private let connector: HostConnector
    private let context: HostConnector.Context
    private let isRetryable: (Error) -> Bool
    private let timing: ConnectionTiming
    private var runner: Task<Void, Never>?
    /// The sleep between reconnect rounds; `retryNow()` ends it early.
    private var backoff: Task<Void, Never>?
    private var lastHeard = ContinuousClock.now
    private var hasConnected = false

    init(
        generation: UInt64, owner: any ConnectionAttemptOwner, connector: HostConnector,
        context: HostConnector.Context, isRetryable: @escaping (Error) -> Bool, timing: ConnectionTiming
    ) {
        self.generation = generation
        self.owner = owner
        self.connector = connector
        self.context = context
        self.isRetryable = isRetryable
        self.timing = timing
    }

    private var isCancelled: Bool { phase == .cancelled }

    func start() {
        guard runner == nil, !isCancelled else { return }
        runner = Task { await run() }
    }

    /// Stops the loop, takes the connection now and closes it. Safe to repeat.
    @discardableResult
    func cancel() -> Task<Void, Never> {
        phase = .cancelled
        runner?.cancel()
        let taken = connection
        connection = nil
        return Task { await taken?.close() }
    }

    /// The network is back: if this attempt is waiting out a backoff, retry now.
    func retryNow() {
        guard phase == .backingOff else { return }
        backoff?.cancel()
    }

    private func run() async {
        var delay = timing.firstDelay
        while !isCancelled {
            phase = .connecting
            do {
                let connection = try await connectOnce()
                delay = timing.firstDelay
                try await follow(connection)
                throw SessionError.connectionLost
            } catch is CancellationError {
                break
            } catch {
                if isCancelled { break }
                let taken = connection
                connection = nil
                await taken?.close()
                if isCancelled { break }
                let retrying = isRetryable(error)
                owner?.attempt(self, failed: error, retrying: retrying)
                guard retrying else {
                    phase = .finished
                    break
                }
                phase = .backingOff
            }
            let nap = Task<Void, Never> { try? await Task.sleep(for: delay) }
            backoff = nap
            await withTaskCancellationHandler { await nap.value } onCancel: { nap.cancel() }
            backoff = nil
            delay = min(delay * 2, timing.maxDelay)
        }
        if !isCancelled { owner?.attemptFinished(self) }
    }

    private func connectOnce() async throws -> HostConnection {
        let gated = HostConnector.Context(
            reconnecting: context.reconnecting || hasConnected,
            progress: { [weak self] text in
                guard let self, self.phase == .connecting, let owner = self.owner else { return }
                owner.attempt(self, progress: text)
                self.context.progress(text)
            },
            signingKey: context.signingKey,
            askToTrust: context.askToTrust)
        let connection = try await connector.connect(gated)
        // Cancelled or replaced while connecting: don't hand a stale line to whatever runs now.
        if isCancelled || Task.isCancelled || owner?.isCurrent(self) != true {
            await connection.close()
            throw CancellationError()
        }
        self.connection = connection
        return connection
    }

    /// Applies events until the stream ends, errors, or goes quiet.
    private func follow(_ connection: HostConnection) async throws {
        let client = connection.client
        // Subscribe first, then read anything else, as the protocol asks.
        let subscription = try await client.subscribeEvents()
        try checkCurrent()
        lastHeard = .now
        hasConnected = true
        phase = .live
        owner?.attempt(self, connected: connection, snapshot: subscription.snapshot)
        // Usable now; the documents follow, each when it arrives.
        let machinesTask = Task { [weak self] in
            let machines = (try? await client.listTerminals().machines) ?? []
            guard let self, !self.isCancelled, !Task.isCancelled else { return }
            self.owner?.attempt(self, machines: machines)
        }
        let layoutTask = Task { [weak self] in
            let layout = try? await client.herdrAppLayout()
            guard let self, !self.isCancelled, !Task.isCancelled else { return }
            self.owner?.attempt(self, layout: layout)
        }
        defer { machinesTask.cancel(); layoutTask.cancel() }

        let (check, limit) = (timing.silenceCheck, timing.silenceLimit)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await message in subscription.messages {
                    await self.deliver(message)
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: check)
                    if await self.silent(longerThan: limit) { throw SessionError.timedOut }
                }
            }
            // The first child to finish (stream ended, error, silence) ends both.
            try await group.next()
            group.cancelAll()
        }
    }

    private func checkCurrent() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    func deliver(_ message: EventMessage) async {
        guard !isCancelled else { return }
        lastHeard = .now
        await owner?.attempt(self, received: message)
    }

    private func silent(longerThan limit: Duration) -> Bool {
        ContinuousClock.now - lastHeard > limit
    }
}
