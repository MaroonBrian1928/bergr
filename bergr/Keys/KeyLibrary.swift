// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
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

    /// Parses and stores a pasted or picked private key. Returns an error message on failure.
    func importKey(text: String, label: String) -> String? {
        do {
            let parsed = try PrivateKeyImporter.parse(text)
            try store.importKey(parsed, label: label)
            reload()
            return nil
        } catch {
            return error.localizedDescription
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
    /// Keys unlocked this time the app is open, and unlocks under way: machines that connect at
    /// once (the Agents screen) share one Face ID prompt instead of cancelling each other's.
    @ObservationIgnored private var unlocked: [UUID: SigningKey] = [:]
    @ObservationIgnored private var unlocking: [UUID: Task<SigningKey, Error>] = [:]

    func signingKey(for key: SSHKeyInfo) async throws -> SigningKey {
        if let ready = unlocked[key.id] { return ready }
        if let running = unlocking[key.id] { return try await running.value }
        let task = Task { try await self.unlock(key) }
        unlocking[key.id] = task
        let generation = lockGeneration
        defer { if unlocking[key.id] == task { unlocking[key.id] = nil } }
        let signing = try await task.value
        // Locked again while it was unlocking: this caller may use it, the cache doesn't keep it.
        if generation == lockGeneration { unlocked[key.id] = signing }
        return signing
    }

    @ObservationIgnored private var lockGeneration = 0

    /// Locks the keys again (the app went to the background without staying connected).
    func forgetUnlocked() {
        unlocked = [:]
        unlocking = [:]
        lockGeneration += 1
    }

    private func unlock(_ key: SSHKeyInfo) async throws -> SigningKey {
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
