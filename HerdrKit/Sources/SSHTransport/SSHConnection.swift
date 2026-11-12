// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
@preconcurrency import Citadel
#if canImport(Network)
import NIOTransportServices
#endif
import Foundation
import KeyStore
import NIOCore
@preconcurrency import NIOSSH

public enum SSHTransportError: Error, LocalizedError {
    case hostKeyChanged(host: String, expected: String, offered: String)
    case hostKeyRejected(host: String)
    case authenticationFailed(username: String)
    case commandFailed(exitCode: Int, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .hostKeyChanged(let host, let expected, let offered):
            "The host key of \(host) changed (expected \(expected), got \(offered)). "
                + "This could be an attack, or the server was reinstalled."
        case .hostKeyRejected(let host): "The host key of \(host) was not trusted."
        case .authenticationFailed(let username): "The server did not accept the key for \(username)."
        case .commandFailed(let code, let stderr):
            stderr.isEmpty ? "The remote command exited with \(code)." : stderr
        }
    }
}

/// An authenticated SSH connection.
public final class SSHConnection: @unchecked Sendable {
    private let client: SSHClient?
    #if os(macOS)
    private let systemClient: SystemSSH?
    #endif
    public let target: SSHTarget
    /// Native Windows OpenSSH identifies itself in its greeting. No exec probe is needed.
    public let isWindowsServer: Bool
    public var usesSystemSSH: Bool { client == nil }

    private init(client: SSHClient, target: SSHTarget, isWindowsServer: Bool = false) {
        self.client = client
        self.target = target
        self.isWindowsServer = isWindowsServer
        #if os(macOS)
        self.systemClient = nil
        #endif
    }

    #if os(macOS)
    private init(system target: SSHTarget) {
        self.target = target
        self.client = nil
        self.isWindowsServer = false
        self.systemClient = SystemSSH(target: target)
    }

    /// OpenSSH uses this Mac's config, known_hosts and ssh-agent. No private key is imported.
    public static func system(to target: SSHTarget) -> SSHConnection {
        SSHConnection(system: target)
    }
    #endif

    /// Connects and logs in with a public key.
    public static func connect(
        to target: SSHTarget,
        key: SigningKey,
        knownHosts: any KnownHostsStore,
        onUnknownHost: @escaping UnknownHostHandler,
        timeout: TimeAmount = .seconds(15)
    ) async throws -> SSHConnection {
        let privateKey: NIOSSHPrivateKey =
            switch key {
            case .secureEnclave(let key): NIOSSHPrivateKey(secureEnclaveP256Key: key)
            case .software(let key): NIOSSHPrivateKey(p256Key: key)
            case .ed25519(let key): NIOSSHPrivateKey(ed25519Key: key)
            }
        let authentication = SSHAuthenticationMethod.custom(PublicKeyAuthentication(username: target.username, key: privateKey))
        let validator = SSHHostKeyValidator.custom(TOFUHostKeyValidator(
            host: target.knownHostsName, store: knownHosts, onUnknownHost: onUnknownHost))
        #if canImport(Network)
        let identification = SSHServerIdentification()
        // Apple's Network framework for the TCP connection, not BSD sockets: it follows iOS's
        // routing as VPN apps (Pangolin, WireGuard) set it up. Over BSD sockets, a LAN address
        // reached through such a VPN timed out while other SSH apps connected.
        let channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(timeout)
            // The server greets as soon as TCP is up, before Citadel adds its handlers: hold
            // what arrives until then, or the greeting is dropped and the handshake waits forever.
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(HoldUntilSSH(identification: identification)) }
            }
            .connect(host: target.host, port: target.port)
            .get()
        var settings = SSHClientSettings(
            host: target.host, port: target.port, authenticationMethod: { authentication }, hostKeyValidator: validator)
        settings.connectTimeout = timeout
        let client: SSHClient
        do {
            // Citadel sets up the pipeline synchronously, which NIO allows only on the channel's
            // loop: run it there (its own bootstrap does that inside the channel initializer).
            client = try await withTaskExecutorPreference(EventLoopTaskExecutor(channel.eventLoop)) {
                try await SSHClient.connect(on: channel, settings: settings)
            }
        } catch {
            try? await channel.close()
            throw error
        }
        #else
        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: authentication,
            hostKeyValidator: validator,
            reconnect: .never,
            connectTimeout: timeout)
        #endif
        #if canImport(Network)
        return SSHConnection(client: client, target: target, isWindowsServer: identification.isWindows)
        #else
        return SSHConnection(client: client, target: target)
        #endif
    }

    public var isConnected: Bool {
        #if os(macOS)
        if let systemClient { return !systemClient.isClosed }
        #endif
        return client?.isConnected == true
    }

    /// Runs a command and returns its stdout.
    public func run(_ command: String) async throws -> String {
        // Citadel's short-command API handles exit status itself. Long-lived ExecPipe streams
        // can surface alreadyClosed when an exec exits; don't use those for startup probes.
        if let client { return String(buffer: try await client.executeCommand(command)) }
        let pipe = try await openExec(command)
        defer { pipe.close() }
        return try await withTaskCancellationHandler {
            var result = Data()
            for try await chunk in pipe.output { result.append(chunk) }
            return String(decoding: result, as: UTF8.self)
        } onCancel: {
            pipe.close()
        }
    }

    /// Starts a long-lived command (no PTY) and gives raw access to its stdin and stdout.
    public func openExec(_ command: String) async throws -> ExecPipe {
        #if os(macOS)
        if let systemClient { return try systemClient.openExec(command) }
        #endif
        guard let client else { throw ChannelError.ioOnClosedChannel }
        return try await ExecPipe.open(command: command, on: client)
    }

    public func close() async {
        #if os(macOS)
        systemClient?.close()
        #endif
        try? await client?.close()
    }
}

/// Offers one public key, once.
final class PublicKeyAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let username: String
    let key: NIOSSHPrivateKey
    private var offered = false

    init(username: String, key: NIOSSHPrivateKey) {
        self.username = username
        self.key = key
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTransportError.authenticationFailed(username: username))
            return
        }
        offered = true
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}

#if canImport(Network)
/// Buffers inbound bytes until the SSH handler is in the pipeline after it, then passes them on
/// in order. Citadel's `connect(on:)` adds that handler only after the connection is up.
final class HoldUntilSSH: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var held: [NIOAny] = []
    private var ready = false
    private let identification: SSHServerIdentification

    init(identification: SSHServerIdentification = SSHServerIdentification()) {
        self.identification = identification
    }

    func flush(context: ChannelHandlerContext) {
        context.flush()
        // NIOSSH flushes its client greeting when installed. Replay on the next loop turn,
        // once all Citadel handlers exist. Waiting for another inbound read can deadlock
        // when the server has already sent its entire greeting and is waiting for ours.
        let bound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        context.eventLoop.execute {
            let (handler, context) = bound.value
            handler.releaseIfReady(context: context)
        }
    }

    private func releaseIfReady(context: ChannelHandlerContext) {
        guard !ready, (try? context.pipeline.syncOperations.handler(type: NIOSSHHandler.self)) != nil else { return }
        ready = true
        let buffered = held
        held.removeAll()
        for data in buffered { context.fireChannelRead(data) }
        if !buffered.isEmpty { context.fireChannelReadComplete() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        identification.receive(unwrapInboundIn(data))
        releaseIfReady(context: context)
        if ready { context.fireChannelRead(data) } else { held.append(data) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if ready { context.fireChannelReadComplete() }
    }
}

/// Reads only the public server greeting, before encrypted SSH traffic begins.
final class SSHServerIdentification: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private var identified = false
    private var windows = false

    var isWindows: Bool { lock.withLock { windows } }

    func receive(_ buffer: ByteBuffer) {
        lock.withLock {
            guard !identified, bytes.count < 8192 else { return }
            bytes.append(contentsOf: buffer.readableBytesView.prefix(8192 - bytes.count))
            // Split bytes, not Swift Characters: CRLF is one grapheme cluster, so splitting
            // a String on a lone newline does not reliably recognize an SSH greeting.
            while let newline = bytes.firstIndex(of: 10) {
                let line = String(decoding: bytes[..<newline], as: UTF8.self)
                bytes.removeSubrange(bytes.startIndex...newline)
                guard line.hasPrefix("SSH-") else { continue }
                windows = line.contains("OpenSSH_for_Windows")
                identified = true
                bytes.removeAll()
                break
            }
        }
    }
}

/// A task executor that runs jobs on a NIO event loop, so nonisolated async code (Citadel's
/// `connect(on:)`) runs on the channel's loop.
private final class EventLoopTaskExecutor: TaskExecutor, @unchecked Sendable {
    let loop: any EventLoop
    init(_ loop: any EventLoop) { self.loop = loop }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        loop.execute { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
#endif
