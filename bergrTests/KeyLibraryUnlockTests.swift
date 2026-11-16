import CryptoKit
import Foundation
import LocalAuthentication
import Testing
@testable import bergr
import HerdrKit

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct KeyLibraryUnlockTests {
    private func key() -> SSHKeyInfo {
        SSHKeyInfo(id: UUID(), label: "Test", kind: .software, requiresBiometry: true,
                   createdAt: Date(), publicKeyX963: Data())
    }

    @MainActor final class Gate {
        var calls = 0
        var continuations: [CheckedContinuation<Void, Error>] = []
        func wait() async throws {
            calls += 1
            try await withCheckedThrowingContinuation { continuations.append($0) }
        }
        func resume(_ result: Result<Void, Error> = .success(())) {
            continuations.removeFirst().resume(with: result)
        }
        func untilCalls(_ count: Int) async {
            while calls < count { await Task.yield() }
        }
    }

    @Test func coalescesCachesAndSerializesDifferentKeys() async throws {
        let gate = Gate()
        var loads = 0
        let library = KeyLibrary(authorize: { _ in try await gate.wait(); return nil }, load: { _, _ in
            loads += 1
            return .software(P256.Signing.PrivateKey())
        })
        let first = key(), second = key()
        let a = Task { try await library.signingKey(for: first) }
        await gate.untilCalls(1)
        var joinerEntered = false
        let b = Task { joinerEntered = true; return try await library.signingKey(for: first) }
        while !joinerEntered { await Task.yield() }
        let c = Task { try await library.signingKey(for: second) }
        await Task.yield()
        #expect(gate.calls == 1)
        gate.resume()
        _ = try await a.value
        _ = try await b.value
        await gate.untilCalls(2)
        #expect(loads == 1)
        gate.resume()
        _ = try await c.value
        _ = try await library.signingKey(for: first)
        #expect(loads == 2)
    }

    @Test func activationPrecedesAuthorization() async throws {
        let activation = Gate(), auth = Gate()
        let library = KeyLibrary(authorize: { _ in try await auth.wait(); return nil },
                                 load: { _, _ in .software(P256.Signing.PrivateKey()) },
                                 waitUntilActive: { try await activation.wait() })
        let task = Task { try await library.signingKey(for: key()) }
        await activation.untilCalls(1)
        #expect(auth.calls == 0)
        activation.resume()
        await auth.untilCalls(1)
        auth.resume()
        _ = try await task.value
    }

    @Test func lockRejectsAllWaitersAndKeepsOldOperationInQueue() async throws {
        let gate = Gate()
        let library = KeyLibrary(authorize: { _ in try await gate.wait(); return nil },
                                 load: { _, _ in .software(P256.Signing.PrivateKey()) })
        let first = key(), second = key()
        let owner = Task { try await library.signingKey(for: first) }
        await gate.untilCalls(1)
        var joinerEntered = false
        let joiner = Task { joinerEntered = true; return try await library.signingKey(for: first) }
        while !joinerEntered { await Task.yield() }
        library.forgetUnlocked()
        let next = Task { try await library.signingKey(for: second) }
        await Task.yield()
        #expect(gate.calls == 1)
        gate.resume()
        do { _ = try await owner.value; Issue.record("Owner received a locked key") } catch {}
        do { _ = try await joiner.value; Issue.record("Joiner received a locked key") } catch {}
        await gate.untilCalls(2)
        gate.resume()
        _ = try await next.value
    }

    @Test func unprotectedKeyDoesNotWaitForBiometry() async throws {
        let gate = Gate()
        var loads = 0
        let library = KeyLibrary(authorize: { _ in try await gate.wait(); return nil }, load: { _, _ in
            loads += 1
            return .software(P256.Signing.PrivateKey())
        })
        let protected = Task { try await library.signingKey(for: key()) }
        await gate.untilCalls(1)
        let plain = SSHKeyInfo(id: UUID(), label: "Plain", kind: .software, requiresBiometry: false,
                               createdAt: Date(), publicKeyX963: Data())
        _ = try await library.signingKey(for: plain)
        #expect(loads == 1)
        gate.resume()
        _ = try await protected.value
    }

    @Test func staleSuccessfulResultIsRejectedForBothWaiters() async throws {
        let gate = Gate()
        var library: KeyLibrary!
        library = KeyLibrary(authorize: { _ in try await gate.wait(); return nil }, load: { _, _ in
            library.forgetUnlocked()
            return .software(P256.Signing.PrivateKey())
        })
        let info = key()
        let owner = Task { try await library.signingKey(for: info) }
        await gate.untilCalls(1)
        var joinerEntered = false
        let joiner = Task { joinerEntered = true; return try await library.signingKey(for: info) }
        while !joinerEntered { await Task.yield() }
        gate.resume()
        do { _ = try await owner.value; Issue.record("Owner received a stale key") } catch {}
        do { _ = try await joiner.value; Issue.record("Joiner received a stale key") } catch {}
    }

    @Test func failureAllowsRetry() async throws {
        struct Failure: Error {}
        let gate = Gate()
        let library = KeyLibrary(authorize: { _ in try await gate.wait(); return nil },
                                 load: { _, _ in .software(P256.Signing.PrivateKey()) })
        let info = key()
        let first = Task { try await library.signingKey(for: info) }
        await gate.untilCalls(1)
        gate.resume(.failure(Failure()))
        do { _ = try await first.value; Issue.record("Expected failure") } catch {}
        let retry = Task { try await library.signingKey(for: info) }
        await gate.untilCalls(2)
        gate.resume()
        _ = try await retry.value
    }
}
