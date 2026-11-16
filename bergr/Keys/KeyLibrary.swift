// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation
import HerdrKit
import LocalAuthentication
import Observation
import OSLog
#if os(iOS)
import UIKit
#endif

// LAContext supports invalidation from the cancellation handler while evaluation is in flight.
// All other access remains on the main actor.
private final class CancellableAuthContext: @unchecked Sendable {
    nonisolated(unsafe) private let context: LAContext

    init(_ context: LAContext) { self.context = context }
    nonisolated func invalidate() { context.invalidate() }
}

/// SwiftUI-facing wrapper around `KeyStore`.
@Observable
final class KeyLibrary {
    private(set) var keys: [SSHKeyInfo] = []
    var lastError: String?
    /// Set when the keychain is closed to this build (no entitlement: an unsigned Mac build).
    /// Keys can't be created, imported or used then; the rest of the app works.
    private(set) var unavailableReason: String?

    private let store: KeyStore
    private let authorize: @MainActor (SSHKeyInfo) async throws -> LAContext?
    private let load: @MainActor (UUID, LAContext?) throws -> SigningKey
    private let waitUntilActive: @MainActor () async throws -> Void

    init(store: KeyStore = KeyStore()) {
        self.store = store
        self.authorize = Self.authorizeKey
        self.load = { try store.signingKey(for: $0, authenticationContext: $1) }
        self.waitUntilActive = Self.waitForActivation
        reload()
    }

    init(
        authorize: @escaping @MainActor (SSHKeyInfo) async throws -> LAContext?,
        load: @escaping @MainActor (UUID, LAContext?) throws -> SigningKey,
        waitUntilActive: @escaping @MainActor () async throws -> Void = {}
    ) {
        self.store = KeyStore()
        self.authorize = authorize
        self.load = load
        self.waitUntilActive = waitUntilActive
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
    // Retain the tail across a lock until the old operation actually exits.
    @ObservationIgnored private var unlockTail: Task<Void, Never>?
    @ObservationIgnored private var lockGeneration = 0

    func signingKey(for key: SSHKeyInfo) async throws -> SigningKey {
        if let ready = unlocked[key.id] { return ready }
        let generation = lockGeneration
        let task: Task<SigningKey, Error>
        if let running = unlocking[key.id] {
            task = running
        } else {
            let previous = key.requiresBiometry ? unlockTail : nil
            task = Task {
                await previous?.value
                try Task.checkCancellation()
                return try await self.unlock(key)
            }
            unlocking[key.id] = task
            if key.requiresBiometry { unlockTail = Task { _ = await task.result } }
        }
        defer { if unlocking[key.id] == task { unlocking[key.id] = nil } }
        let signing = try await task.value
        guard generation == lockGeneration else { throw CancellationError() }
        unlocked[key.id] = signing
        return signing
    }

    /// Locks the keys again (the app went to the background without staying connected).
    func forgetUnlocked() {
        lockGeneration += 1
        for task in unlocking.values { task.cancel() }
        unlocked = [:]
        unlocking = [:]
    }

    private func unlock(_ key: SSHKeyInfo) async throws -> SigningKey {
        var context: LAContext?
        if key.requiresBiometry {
            try await waitUntilActive()
            try Task.checkCancellation()
            context = try await authorize(key)
        }
        try Task.checkCancellation()
        return try load(key.id, context)
    }

    private static let authLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "bergr", category: "authentication")

    private static func waitForActivation() async throws {
        #if os(iOS)
        if UIApplication.shared.applicationState != .active { authLog.info("Waiting for app activation") }
        while UIApplication.shared.applicationState != .active {
            try await Task.sleep(for: .milliseconds(50))
        }
        #endif
        try Task.checkCancellation()
    }

    private static func authorizeKey(_ key: SSHKeyInfo) async throws -> LAContext? {
        let context = LAContext()
        let cancellableContext = CancellableAuthContext(context)
        let log = authLog
        log.info("Authentication started")
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await context.evaluatePolicy(
                    KeyStore.isMac ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock “\(key.label)” to connect")
                try Task.checkCancellation()
            } onCancel: {
                log.info("Authentication cancelled")
                cancellableContext.invalidate()
            }
            log.info("Authentication succeeded")
        } catch {
            let nsError = error as NSError
            authLog.info("Authentication failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            throw error
        }
        return context
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
