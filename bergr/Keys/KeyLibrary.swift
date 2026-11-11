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
    /// Set when the keychain is closed to this build (no entitlement: an unsigned Mac build).
    /// Keys can't be created, imported or used then; the rest of the app works.
    private(set) var unavailableReason: String?

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
            note(error)
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
            note(error)
            return error.localizedDescription
        }
    }

    /// Private keys found in `~/.ssh` (Mac only: elsewhere there is nothing to read).
    func discoverSSHFolder() -> [DiscoveredKey] {
        #if os(macOS)
        SSHFolder.discover()
        #else
        []
        #endif
    }

    /// Imports one file from `~/.ssh`. Returns an error message on failure.
    func importFile(_ url: URL, label: String = "") -> String? {
        do {
            return importKey(text: try SSHFolder.read(url), label: label)
        } catch {
            return error.localizedDescription
        }
    }

    /// Remembers why keys are unavailable, when that is why `error` happened.
    private func note(_ error: Error) {
        if let keyError = error as? KeyStoreError, keyError.isKeychainUnavailable {
            unavailableReason = keyError.localizedDescription
        } else {
            lastError = error.localizedDescription
        }
    }

    func rename(_ key: SSHKeyInfo, to label: String) {
        do {
            try store.rename(id: key.id, to: label)
            reload()
        } catch {
            note(error)
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
            // On a Mac the key was made with `.userPresence`: Touch ID, Watch or the password.
            try await unlock.evaluatePolicy(
                KeyStore.isMac ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "Unlock “\(key.label)” to connect")
            context = unlock
        }
        return try store.signingKey(for: key.id, authenticationContext: context)
    }

    private func reload() {
        do {
            keys = try store.keys()
            unavailableReason = nil
        } catch {
            keys = []
            note(error)
        }
    }
}
