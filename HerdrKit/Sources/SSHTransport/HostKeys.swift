// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation
import KeyStore
import NIOCore
@preconcurrency import NIOSSH

/// Where an SSH server lives and who we log in as.
public struct SSHTarget: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int = 22, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// Key for known hosts, as OpenSSH writes it (`host` or `[host]:port`).
    public var knownHostsName: String {
        port == 22 ? host : "[\(host)]:\(port)"
    }
}

/// A server's host key, offered for trust on first use.
public struct HostKey: Sendable, Hashable {
    public let host: String
    /// `type base64` as in `known_hosts`.
    public let openSSHLine: String

    public var fingerprint: String {
        OpenSSH.sha256Fingerprint(publicKeyLine: openSSHLine) ?? "?"
    }
}

/// Remembers which host key belongs to which host.
public protocol KnownHostsStore: Sendable {
    func hostKey(for host: String) -> String?
    func setHostKey(_ openSSHLine: String, for host: String)
    func removeHostKey(for host: String)
}

public final class UserDefaultsKnownHosts: KnownHostsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "bergr.known-hosts"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var all: [String: String] {
        get { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: key) }
    }

    public func hostKey(for host: String) -> String? { all[host] }
    public func setHostKey(_ openSSHLine: String, for host: String) { all[host] = openSSHLine }
    public func removeHostKey(for host: String) { all[host] = nil }
}

public final class InMemoryKnownHosts: KnownHostsStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func hostKey(for host: String) -> String? { lock.withLock { keys[host] } }
    public func setHostKey(_ openSSHLine: String, for host: String) { lock.withLock { keys[host] = openSSHLine } }
    public func removeHostKey(for host: String) { lock.withLock { _ = keys.removeValue(forKey: host) } }
}

/// Asked once per unknown host; return true to trust and remember its key.
public typealias UnknownHostHandler = @Sendable (HostKey) async -> Bool

/// Trust on first use: a known host must present the same key; an unknown one is asked about.
final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let host: String
    let store: any KnownHostsStore
    let onUnknownHost: UnknownHostHandler

    init(host: String, store: any KnownHostsStore, onUnknownHost: @escaping UnknownHostHandler) {
        self.host = host
        self.store = store
        self.onUnknownHost = onUnknownHost
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let offered = HostKey(host: host, openSSHLine: String(openSSHPublicKey: hostKey))
        if let known = store.hostKey(for: host) {
            if known == offered.openSSHLine {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHTransportError.hostKeyChanged(
                    host: host,
                    expected: OpenSSH.sha256Fingerprint(publicKeyLine: known) ?? "?",
                    offered: offered.fingerprint))
            }
            return
        }
        let (store, host, ask) = (store, host, onUnknownHost)
        Task {
            if await ask(offered) {
                store.setHostKey(offered.openSSHLine, for: host)
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(SSHTransportError.hostKeyRejected(host: host))
            }
        }
    }
}

/// Parses an OpenSSH public key line with NIOSSH and writes it back (`type base64`), or nil if NIOSSH rejects it.
func normalizedOpenSSHPublicKey(_ line: String) -> String? {
    let parts = line.split(separator: " ")
    guard parts.count >= 2, let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(parts[0]) \(parts[1])") else {
        return nil
    }
    return String(openSSHPublicKey: key)
}
