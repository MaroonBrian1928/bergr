import Foundation
import HerdrKit
import LocalAuthentication
import Observation

/// SwiftUI-facing wrapper around `KeyStore`.
@Observable
final class KeyLibrary {
    private(set) var keys: [SSHKeyInfo] = []
    var lastError: String?

    private let store: KeyStore

    init(store: KeyStore = KeyStore()) {
        self.store = store
        reload()
    }

    var hasSecureEnclave: Bool { KeyStore.isSecureEnclaveAvailable }

    func key(id: UUID?) -> SSHKeyInfo? {
        keys.first { $0.id == id }
    }

    @discardableResult
    func generate(label: String, requireBiometry: Bool) -> SSHKeyInfo? {
        do {
            let info = try store.generateKey(label: label, requireBiometry: requireBiometry)
            reload()
            return info
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func rename(_ key: SSHKeyInfo, to label: String) {
        do {
            try store.rename(id: key.id, to: label)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(_ key: SSHKeyInfo) {
        do {
            try store.deleteKey(id: key.id)
            reload()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Loads the private key, asking for Face ID first if the key needs it, so the
    /// prompt does not appear in the middle of the SSH handshake.
    func signingKey(for key: SSHKeyInfo) async throws -> SigningKey {
        var context: LAContext?
        if key.requiresBiometry {
            let unlock = LAContext()
            try await unlock.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock “\(key.label)” to connect")
            context = unlock
        }
        return try store.signingKey(for: key.id, authenticationContext: context)
    }

    private func reload() {
        do {
            keys = try store.keys()
        } catch {
            lastError = error.localizedDescription
        }
    }
}
