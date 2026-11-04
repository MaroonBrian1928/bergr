@preconcurrency import Citadel
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
            }
        let client = try await SSHClient.connect(
            host: target.host,
            port: target.port,
            authenticationMethod: .custom(PublicKeyAuthentication(username: target.username, key: privateKey)),
            hostKeyValidator: .custom(TOFUHostKeyValidator(
                host: target.knownHostsName, store: knownHosts, onUnknownHost: onUnknownHost)),
            reconnect: .never,
            connectTimeout: timeout)
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
