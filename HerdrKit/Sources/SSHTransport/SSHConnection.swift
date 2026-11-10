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
    private let client: SSHClient
    public let target: SSHTarget

    private init(client: SSHClient, target: SSHTarget) {
        self.client = client
        self.target = target
    }

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
        // Apple's Network framework for the TCP connection, not BSD sockets: it follows iOS's
        // routing as VPN apps (Pangolin, WireGuard) set it up. Over BSD sockets, a LAN address
        // reached through such a VPN timed out while other SSH apps connected.
        let channel = try await NIOTSConnectionBootstrap(group: NIOTSEventLoopGroup.singleton)
            .connectTimeout(timeout)
            // The server greets as soon as TCP is up, before Citadel adds its handlers: hold
            // what arrives until then, or the greeting is dropped and the handshake waits forever.
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(HoldUntilSSH()) }
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
        return SSHConnection(client: client, target: target)
    }

    public var isConnected: Bool { client.isConnected }

    /// Runs a command and returns its stdout.
    public func run(_ command: String) async throws -> String {
        let output = try await client.executeCommand(command)
        return String(buffer: output)
    }

    /// Starts a long-lived command (no PTY) and gives raw access to its stdin and stdout.
    public func openExec(_ command: String) async throws -> ExecPipe {
        try await ExecPipe.open(command: command, on: client)
    }

    public func close() async {
        try? await client.close()
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
private final class HoldUntilSSH: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private var held: [NIOAny] = []
    private var ready = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !ready, (try? context.pipeline.syncOperations.handler(type: NIOSSHHandler.self)) != nil {
            ready = true
            for buffered in held { context.fireChannelRead(buffered) }
            held.removeAll()
        }
        if ready { context.fireChannelRead(data) } else { held.append(data) }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if ready { context.fireChannelReadComplete() }
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
