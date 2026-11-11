// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Where the private key lives.
public enum SSHKeyKind: String, Codable, Sendable {
    /// Generated inside the Secure Enclave; the private key never leaves the chip.
    case secureEnclave
    /// A plain P-256 key stored in the Keychain. Fallback for the simulator.
    case software
    /// A key the user imported (ed25519 or P-256), stored in the Keychain.
    case imported
}

public enum SSHKeyAlgorithm: String, Codable, Sendable {
    case p256
    case ed25519
}

/// Public facts about a stored key. Safe to show and pass around.
public struct SSHKeyInfo: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var label: String
    public let kind: SSHKeyKind
    public let requiresBiometry: Bool
    public let createdAt: Date
    /// Public key bytes: uncompressed P-256 point (0x04 || X || Y), or the 32 raw ed25519 bytes.
    public let publicKeyX963: Data
    /// Missing in records written before key import existed: those are P-256.
    public let algorithm: SSHKeyAlgorithm

    public init(
        id: UUID, label: String, kind: SSHKeyKind, requiresBiometry: Bool, createdAt: Date,
        publicKeyX963: Data, algorithm: SSHKeyAlgorithm = .p256
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.requiresBiometry = requiresBiometry
        self.createdAt = createdAt
        self.publicKeyX963 = publicKeyX963
        self.algorithm = algorithm
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        kind = try c.decode(SSHKeyKind.self, forKey: .kind)
        requiresBiometry = try c.decode(Bool.self, forKey: .requiresBiometry)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        publicKeyX963 = try c.decode(Data.self, forKey: .publicKeyX963)
        algorithm = try c.decodeIfPresent(SSHKeyAlgorithm.self, forKey: .algorithm) ?? .p256
    }

    /// The P-256 public key, or nil for other algorithms.
    public var publicKey: P256.Signing.PublicKey? {
        algorithm == .p256 ? try? P256.Signing.PublicKey(x963Representation: publicKeyX963) : nil
    }

    /// The SSH wire-format public key blob.
    public var publicKeyBlob: Data {
        switch algorithm {
        case .p256: publicKey.map(OpenSSH.publicKeyBlob) ?? Data()
        case .ed25519:
            (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyX963)).map(OpenSSH.publicKeyBlob) ?? Data()
        }
    }

    public var algorithmName: String {
        algorithm == .ed25519 ? OpenSSH.ed25519KeyType : OpenSSH.ecdsaP256KeyType
    }

    /// Paste this into `~/.ssh/authorized_keys` on the server.
    public var authorizedKeysLine: String {
        OpenSSH.line(type: algorithmName, blob: publicKeyBlob, comment: label)
    }

    public var fingerprint: String {
        OpenSSH.sha256Fingerprint(blob: publicKeyBlob)
    }
}

/// A private key ready to sign an SSH login.
public enum SigningKey: @unchecked Sendable {
    case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
    case software(P256.Signing.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)

    /// The P-256 public key, or nil for ed25519.
    public var publicKey: P256.Signing.PublicKey? {
        switch self {
        case .secureEnclave(let key): key.publicKey
        case .software(let key): key.publicKey
        case .ed25519: nil
        }
    }
}

public enum KeyStoreError: Error, LocalizedError {
    case notFound(UUID)
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    /// The data protection keychain is closed to this build: it has no `keychain-access-groups`
    /// entitlement (an unsigned or ad-hoc signed Mac build). Importing or creating keys can't work;
    /// the rest of the app still can.
    case keychainUnavailable
    case accessControl(String)

    /// `errSecMissingEntitlement`.
    public static let missingEntitlementStatus: OSStatus = -34018

    /// The error for a failed keychain call, with the missing-entitlement case set apart.
    public static func keychain(status: OSStatus) -> KeyStoreError {
        status == missingEntitlementStatus ? .keychainUnavailable : .keychain(status)
    }

    public var isKeychainUnavailable: Bool {
        if case .keychainUnavailable = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "No key with id \(id)."
        case .secureEnclaveUnavailable: "This device has no Secure Enclave."
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        case .keychainUnavailable:
            "Keys are unavailable in this build: it isn't signed with the keychain entitlement. "
                + "Use a release build of Bergr, or the system ssh with your own key."
        case .accessControl(let message): "Could not set up key access control: \(message)"
        }
    }
}

/// Creates, lists and loads SSH keys.
///
/// Secure Enclave keys are stored as their `dataRepresentation`: an opaque
/// handle that only this device's Secure Enclave can use.
public final class KeyStore: Sendable {
    private let storage: any KeyStorage

    public init(storage: any KeyStorage = KeychainKeyStorage()) {
        self.storage = storage
    }

    public static var isSecureEnclaveAvailable: Bool { SecureEnclave.isAvailable }

    /// Access control flags for a new Secure Enclave key. On a Mac a biometry-only flag would lock
    /// out machines without Touch ID (mini, Studio, clamshell), so there it is `.userPresence`:
    /// Touch ID, Apple Watch or the login password.
    public static func accessFlags(
        requireBiometry: Bool, isMac: Bool = KeyStore.isMac
    ) -> SecAccessControlCreateFlags {
        guard requireBiometry else { return [.privateKeyUsage] }
        return isMac ? [.privateKeyUsage, .userPresence] : [.privateKeyUsage, .biometryCurrentSet]
    }

    public static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public func keys() throws -> [SSHKeyInfo] {
        try records().map(\.info).sorted { $0.createdAt < $1.createdAt }
    }

    /// Creates a key in the Secure Enclave, or a software key where there is none
    /// (the simulator) and `allowSoftwareFallback` is set.
    @discardableResult
    public func generateKey(
        label: String,
        requireBiometry: Bool = false,
        allowSoftwareFallback: Bool = true
    ) throws -> SSHKeyInfo {
        let record: StoredKey
        if Self.isSecureEnclaveAvailable {
            let flags = Self.accessFlags(requireBiometry: requireBiometry)
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &error
            ) else {
                throw KeyStoreError.accessControl(
                    error.map { "\($0.takeRetainedValue())" } ?? "unknown")
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            record = StoredKey(
                info: SSHKeyInfo(
                    id: UUID(), label: label, kind: .secureEnclave, requiresBiometry: requireBiometry,
                    createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
                keyData: key.dataRepresentation)
        } else if allowSoftwareFallback {
            let key = P256.Signing.PrivateKey()
            record = StoredKey(
                info: SSHKeyInfo(
                    id: UUID(), label: label, kind: .software, requiresBiometry: false,
                    createdAt: Date(), publicKeyX963: key.publicKey.x963Representation),
                keyData: key.rawRepresentation)
        } else {
            throw KeyStoreError.secureEnclaveUnavailable
        }
        try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
        return record.info
    }

    /// Stores a parsed private key in the Keychain.
    @discardableResult
    public func importKey(_ imported: ImportedPrivateKey, label: String? = nil) throws -> SSHKeyInfo {
        let name = label?.trimmingCharacters(in: .whitespaces).nilIfEmpty
            ?? imported.comment ?? "Imported key"
        let publicBytes: Data
        let raw: Data
        let algorithm: SSHKeyAlgorithm
        switch imported.material {
        case .ed25519(let key):
            publicBytes = key.publicKey.rawRepresentation
            raw = key.rawRepresentation
            algorithm = .ed25519
        case .p256(let key):
            publicBytes = key.publicKey.x963Representation
            raw = key.rawRepresentation
            algorithm = .p256
        }
        let record = StoredKey(
            info: SSHKeyInfo(
                id: UUID(), label: name, kind: .imported, requiresBiometry: false,
                createdAt: Date(), publicKeyX963: publicBytes, algorithm: algorithm),
            keyData: raw)
        try storage.save(try JSONEncoder().encode(record), account: record.info.id.uuidString)
        return record.info
    }

    /// Loads the private key for signing.
    ///
    /// For a key that requires biometry, pass an `LAContext` that already passed
    /// `evaluatePolicy`, so signing does not prompt in the middle of the SSH handshake.
    public func signingKey(for id: UUID, authenticationContext: LAContext? = nil) throws -> SigningKey {
        guard let record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        switch record.info.kind {
        case .secureEnclave:
            return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(
                dataRepresentation: record.keyData, authenticationContext: authenticationContext))
        case .software:
            return .software(try P256.Signing.PrivateKey(rawRepresentation: record.keyData))
        case .imported:
            switch record.info.algorithm {
            case .ed25519: return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: record.keyData))
            case .p256: return .software(try P256.Signing.PrivateKey(rawRepresentation: record.keyData))
            }
        }
    }

    public func rename(id: UUID, to label: String) throws {
        guard var record = try records().first(where: { $0.info.id == id }) else {
            throw KeyStoreError.notFound(id)
        }
        record.info.label = label
        try storage.save(try JSONEncoder().encode(record), account: id.uuidString)
    }

    public func deleteKey(id: UUID) throws {
        try storage.delete(account: id.uuidString)
    }

    private func records() throws -> [StoredKey] {
        // Skip entries we cannot read rather than hiding every key.
        try storage.loadAll().compactMap { try? JSONDecoder().decode(StoredKey.self, from: $0) }
    }
}

struct StoredKey: Codable {
    var info: SSHKeyInfo
    /// Secure Enclave handle or raw software key.
    var keyData: Data
}

// MARK: - Storage

/// Persists opaque key records.
public protocol KeyStorage: Sendable {
    func loadAll() throws -> [Data]
    func save(_ data: Data, account: String) throws
    func delete(account: String) throws
}

/// Generic-password items in the data protection keychain, never synced off the device.
public struct KeychainKeyStorage: KeyStorage {
    public let service: String

    public init(service: String = "bergr.ssh-keys") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func loadAll() throws -> [Data] {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecValueData as String] as? Data }
    }

    public func save(_ data: Data, account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeyStoreError.keychain(status: status) }
    }

    public func delete(account: String) throws {
        var query = baseQuery
        query[kSecAttrAccount as String] = account
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.keychain(status: status)
        }
    }
}

/// For tests and previews.
public final class InMemoryKeyStorage: KeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    public init() {}

    public func loadAll() throws -> [Data] { lock.withLock { Array(items.values) } }
    public func save(_ data: Data, account: String) throws { lock.withLock { items[account] = data } }
    public func delete(account: String) throws { lock.withLock { _ = items.removeValue(forKey: account) } }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
