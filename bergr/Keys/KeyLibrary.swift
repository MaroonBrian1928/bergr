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
    /// The last Face ID that succeeded, shared by keys unlocked soon after (see `unlock`).
    @ObservationIgnored private var recentAuth: (context: LAContext, at: Date, generation: Int)?
    static let authReuse: TimeInterval = 30

    func signingKey(for key: SSHKeyInfo) async throws -> SigningKey {
        if let ready = unlocked[key.id] { return ready }
        if key.requiresBiometry {
            AuthTrail.note("asked for \(key.label) (gen \(lockGeneration), \(unlocking[key.id] == nil ? "new" : "joins running"))")
        }
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
        guard generation == lockGeneration else {
            AuthTrail.note("result for \(key.label) dropped: locked meanwhile (gen \(generation) → \(lockGeneration))")
            throw CancellationError()
        }
        unlocked[key.id] = signing
        return signing
    }

    /// Whether `id` is unlocked now (not locked again since): a connection's own copy of a key
    /// unlocked before the app went to the background mustn't be reused after.
    func isUnlocked(_ id: UUID) -> Bool { unlocked[id] != nil }

    /// Locks the keys again (the app went to the background without staying connected).
    func forgetUnlocked() {
        AuthTrail.note("keys locked (app to background); \(unlocking.count) unlock(s) cancelled")
        lockGeneration += 1
        recentAuth = nil
        for task in unlocking.values { task.cancel() }
        unlocked = [:]
        unlocking = [:]
    }

    private func unlock(_ key: SSHKeyInfo) async throws -> SigningKey {
        var context: LAContext?
        if key.requiresBiometry {
            try await waitUntilActive()
            try Task.checkCancellation()
            // One Face ID for every key unlocked together: coming back reconnects all machines,
            // and machines with different keys each asked again, back to back.
            if let recent = recentAuth, recent.generation == lockGeneration,
               Date.now.timeIntervalSince(recent.at) < Self.authReuse {
                context = recent.context
                AuthTrail.note("reused recent Face ID for \(key.label)")
            } else {
                let generation = lockGeneration
                context = try await authorize(key)
                if let context, generation == lockGeneration {
                    recentAuth = (context, .now, generation)
                }
            }
        }
        try Task.checkCancellation()
        return try load(key.id, context)
    }

    private static let authLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "bergr", category: "authentication")

    /// LAError codes by name, for the Face ID log.
    nonisolated static func describe(_ error: NSError) -> String {
        guard error.domain == LAErrorDomain, let code = LAError.Code(rawValue: error.code) else {
            return "\(error.domain) \(error.code)"
        }
        switch code {
        case .userCancel: return "you cancelled (userCancel)"
        case .systemCancel: return "iOS cancelled it (systemCancel)"
        case .appCancel: return "Bergr cancelled it (appCancel)"
        case .userFallback: return "passcode chosen (userFallback)"
        case .authenticationFailed: return "face not recognized"
        case .biometryLockout: return "Face ID locked out"
        case .notInteractive: return "not allowed to show UI (notInteractive)"
        default: return "LAError \(error.code)"
        }
    }

    private static func waitForActivation() async throws {
        #if os(iOS)
        var waited = false
        if UIApplication.shared.applicationState != .active { authLog.info("Waiting for app activation") }
        while UIApplication.shared.applicationState != .active {
            waited = true
            try await Task.sleep(for: .milliseconds(50))
        }
        // Just come to the front (from the background or a notification): iOS cancels a Face ID
        // prompt shown while the switch is still finishing, so let it settle first.
        if waited { try await Task.sleep(for: .milliseconds(600)) }
        #endif
        try Task.checkCancellation()
    }

    /// Asks for Face ID; when iOS itself cancels the prompt (the app was still coming to the front),
    /// asks once more on its own instead of leaving "Unlocking was canceled" and a Retry.
    private static func authorizeKey(_ key: SSHKeyInfo) async throws -> LAContext? {
        do {
            return try await authorizeOnce(key)
        } catch let error as LAError where error.code == .systemCancel && !Task.isCancelled {
            authLog.info("Authentication cancelled by the system; asking again")
            await AuthTrail.note("cancelled by iOS (systemCancel); asking again")
            try await Task.sleep(for: .milliseconds(600))
            try await waitForActivation()
            return try await authorizeOnce(key)
        }
    }

    private static func authorizeOnce(_ key: SSHKeyInfo) async throws -> LAContext? {
        let context = LAContext()
        let cancellableContext = CancellableAuthContext(context)
        let log = authLog
        log.info("Authentication started")
        await AuthTrail.note("Face ID prompt for \(key.label)")
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await context.evaluatePolicy(
                    KeyStore.isMac ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics,
                    localizedReason: "Unlock “\(key.label)” to connect")
                try Task.checkCancellation()
            } onCancel: {
                log.info("Authentication cancelled")
                Task { @MainActor in AuthTrail.note("prompt cancelled by Bergr (task cancelled)") }
                cancellableContext.invalidate()
            }
            log.info("Authentication succeeded")
            await AuthTrail.note("Face ID succeeded")
        } catch {
            let nsError = error as NSError
            authLog.info("Authentication failed: domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            await AuthTrail.note("Face ID failed: \(Self.describe(nsError))")
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
