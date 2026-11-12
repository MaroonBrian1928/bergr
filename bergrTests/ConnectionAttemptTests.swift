import Foundation
import HerdrKit
import Testing

@testable import bergr

/// A connector whose connects wait on gates the test opens, and which records closes by index.
@MainActor
private final class FakeLine {
    private(set) var started = 0
    private(set) var closes: [Int] = []
    private(set) var clients: [HerdrClient] = []
    private var open: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Connect number → error to throw once its gate opens.
    var failures: [Int: Error] = [:]

    var connector: HostConnector {
        HostConnector { [self] _ in
            let n = started
            started += 1
            // Ignores cancellation on purpose: the attempt must clean up after it.
            if !open.contains(n) { await withCheckedContinuation { waiting[n] = $0 } }
            if let error = failures[n] { throw error }
            let client = try await HerdrClient.connectDemo()
            clients.append(client)
            return HostConnection(
                client: client, ssh: nil, coreName: "Fake", coreVersion: nil,
                close: { await client.close(); await self.recordClose(n) })
        }
    }

    private func recordClose(_ n: Int) { closes.append(n) }

    func release(_ n: Int) {
        open.insert(n)
        waiting.removeValue(forKey: n)?.resume()
    }
}

@MainActor
private func eventually(_ what: String = "", _ condition: () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Gives anything wrongly still in flight a moment to land before asserting that nothing did.
@MainActor
private func settle() async { try? await Task.sleep(for: .milliseconds(40)) }

@MainActor
private func makeSession(_ line: FakeLine) -> HostSession {
    let timing = ConnectionTiming(
        firstDelay: .milliseconds(5), maxDelay: .milliseconds(20),
        silenceLimit: .seconds(5), silenceCheck: .seconds(1))
    return HostSession(
        host: Host(name: "fake", target: SSHTarget(host: "fake", username: "u")),
        knownHosts: UserDefaultsKnownHosts(), connector: line.connector, timing: timing)
}

@MainActor
@Suite struct ConnectionAttemptTests {
    let keys = KeyLibrary()

    @Test func retryWhileConnectingClosesOnlyTheOldLine() async {
        let line = FakeLine()
        let session = makeSession(line)
        session.start(keys: keys)
        #expect(await eventually { line.started == 1 })
        session.retry(keys: keys)
        #expect(await eventually { line.started == 2 })
        line.release(0)
        #expect(await eventually { line.closes == [0] })
        line.release(1)
        #expect(await eventually { session.state == .connected })
        await settle()
        #expect(line.closes == [0])
        #expect(session.state == .connected)
        #expect(session.isActive)
        session.stop()
    }

    @Test func stopDuringConnectPublishesNothing() async {
        let line = FakeLine()
        let session = makeSession(line)
        session.start(keys: keys)
        #expect(await eventually { line.started == 1 })
        session.stop()
        line.release(0)
        #expect(await eventually { line.closes == [0] })
        await settle()
        #expect(session.state == .idle)
        #expect(session.snapshot == nil)
        #expect(!session.isActive)
    }

    @Test func lateFailureOfOldAttemptDoesNotFailNewOne() async {
        let line = FakeLine()
        line.failures[0] = SessionError.noKey
        let session = makeSession(line)
        session.start(keys: keys)
        #expect(await eventually { line.started == 1 })
        session.retry(keys: keys)
        #expect(await eventually { line.started == 2 })
        line.release(1)
        #expect(await eventually { session.state == .connected })
        line.release(0)
        await settle()
        #expect(session.state == .connected)
        #expect(session.isActive)
        #expect(line.closes.isEmpty)
        session.stop()
    }

    @Test func stopThenRetryTeardownOrder() async {
        let line = FakeLine()
        let session = makeSession(line)
        line.release(0)
        line.release(1)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        session.stop()
        session.retry(keys: keys)
        #expect(await eventually { line.started == 2 && session.state == .connected })
        await settle()
        // The old line is closed, the new one is not.
        #expect(line.closes == [0])
        #expect(session.state == .connected)
        session.stop()
        #expect(await eventually { line.closes == [0, 1] })
    }

    @Test func nonRetryableEndsAttempt() async {
        let line = FakeLine()
        line.failures[0] = SessionError.noKey
        let session = makeSession(line)
        line.release(0)
        session.start(keys: keys)
        #expect(await eventually { !session.isActive })
        guard case .failed(_, let retrying) = session.state else {
            Issue.record("expected failed, got \(session.state)")
            return
        }
        #expect(!retrying)
        line.release(1)
        session.retry(keys: keys)
        #expect(await eventually { session.state == .connected })
        #expect(session.isActive)
        session.stop()
    }

    @Test func backsOffAndReconnects() async {
        let line = FakeLine()
        let session = makeSession(line)
        line.release(0)
        line.release(1)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        // The line drops.
        await line.clients[0].close()
        #expect(await eventually { line.started == 2 && session.state == .connected })
        #expect(session.isActive)
        #expect(line.closes.contains(0))
        session.stop()
    }

    @Test func pauseTwiceStillResumes() async {
        let line = FakeLine()
        let session = makeSession(line)
        line.release(0)
        line.release(1)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        session.pause()
        session.pause()
        #expect(session.intent == .paused)
        #expect(!session.isActive)
        session.resume(keys: keys)
        #expect(await eventually { line.started == 2 && session.state == .connected })
        #expect(session.intent == .running)
        session.stop()
    }

    @Test func foregroundReplacesAnApparentlyLiveBackgroundConnection() async {
        let line = FakeLine()
        let session = makeSession(line)
        line.release(0)
        line.release(1)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        let revision = session.connectionRevision
        session.resumeAfterBackground(keys: keys)
        #expect(await eventually { line.started == 2 && session.state == .connected })
        #expect(session.connectionRevision == revision + 1)
        #expect(await eventually { line.closes.contains(0) })
        session.stop()
        session.resumeAfterBackground(keys: keys)
        await settle()
        #expect(line.started == 2)
    }

    @Test func newConnectionBypassesRecentAttachDebounce() async throws {
        let line = FakeLine()
        let session = makeSession(line)
        line.release(0)
        line.release(1)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        let terminal = try #require(session.terminals.first)
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.start(session: session, address: terminal.address, cols: 80, rows: 24)
        #expect(await eventually { model.phase == .live })
        // A new line within the old 3-second debounce must reattach without leaving the chat.
        session.resumeAfterBackground(keys: keys)
        #expect(await eventually { line.started == 2 && session.state == .connected })
        model.reconnect()
        #expect(await eventually { model.phase == .live })
        // A covering sheet can disappear/reappear just after attaching, too.
        model.stop()
        model.reconnect()
        #expect(await eventually { model.phase == .live })
        model.stop()
        session.stop()
    }

    @Test func resumeDoesNotStartStoppedSessions() async {
        let line = FakeLine()
        let session = makeSession(line)
        session.resume(keys: keys)
        session.pause()
        session.resume(keys: keys)
        line.release(0)
        session.start(keys: keys)
        #expect(await eventually { session.state == .connected })
        session.stop()
        session.pause()
        session.resume(keys: keys)
        await settle()
        #expect(line.started == 1)
        #expect(!session.isActive)
        #expect(session.intent == .stopped)
    }

    @Test func pauseDuringConnectThenResume() async {
        let line = FakeLine()
        let session = makeSession(line)
        session.start(keys: keys)
        #expect(await eventually { line.started == 1 })
        session.pause()
        #expect(session.intent == .paused)
        line.release(0)
        #expect(await eventually { line.closes == [0] })
        await settle()
        #expect(session.state == .idle)
        session.resume(keys: keys)
        #expect(await eventually { line.started == 2 })
        line.release(1)
        #expect(await eventually { session.state == .connected })
        #expect(line.closes == [0])
        session.stop()
    }

    @Test func probeRetriesAtOnceWhileBackingOff() async {
        let line = FakeLine()
        line.failures[0] = SessionError.connectionLost
        line.release(0)
        line.release(1)
        let timing = ConnectionTiming(
            firstDelay: .seconds(30), maxDelay: .seconds(30), silenceLimit: .seconds(5), silenceCheck: .seconds(1))
        let session = HostSession(
            host: Host(name: "fake", target: SSHTarget(host: "fake", username: "u")),
            knownHosts: UserDefaultsKnownHosts(), connector: line.connector, timing: timing)
        session.start(keys: keys)
        #expect(await eventually {
            if case .failed(_, retrying: true) = session.state { return true }
            return false
        })
        await settle()
        #expect(line.started == 1)
        // The network came back.
        session.probe(keys: keys)
        #expect(await eventually { line.started == 2 && session.state == .connected })
        session.stop()
    }

    @Test func connectedIsReportedBeforeTheDocumentsArrive() async {
        let line = FakeLine()
        line.release(0)
        let owner = RecordingOwner()
        let attempt = ConnectionAttempt(
            generation: 1, owner: owner, connector: line.connector,
            context: .init(
                reconnecting: false, progress: { _ in },
                signingKey: { throw SessionError.noKey }, askToTrust: { _ in false }),
            isRetryable: { _ in true }, timing: ConnectionTiming())
        owner.current = attempt
        attempt.start()
        #expect(await eventually { owner.events.contains("machines") && owner.events.contains("layout") })
        #expect(owner.events.first == "connected")
        await attempt.cancel().value
    }

    @Test func historyRequestSize() {
        #expect(TerminalScreenModel.historyLines(shown: true, expensive: false) == 1000)
        #expect(TerminalScreenModel.historyLines(shown: true, expensive: true) == 200)
        #expect(TerminalScreenModel.historyLines(shown: false, expensive: false) == 200)
        #expect(TerminalScreenModel.historyLines(shown: false, expensive: true) == 200)
        #expect(HostSession.checkInterval(expensive: false) == .seconds(3))
        #expect(HostSession.checkInterval(expensive: true) == .seconds(6))
    }

    @Test func eventAfterCancelIsDropped() async {
        let line = FakeLine()
        line.release(0)
        let owner = RecordingOwner()
        let attempt = ConnectionAttempt(
            generation: 1, owner: owner, connector: line.connector,
            context: .init(
                reconnecting: false, progress: { _ in },
                signingKey: { throw SessionError.noKey }, askToTrust: { _ in false }),
            isRetryable: { _ in true }, timing: ConnectionTiming())
        owner.current = attempt
        attempt.start()
        #expect(await eventually { owner.connected == 1 })
        await attempt.deliver(.heartbeat(seq: 1))
        #expect(owner.received == 1)
        await attempt.cancel().value
        await attempt.deliver(.heartbeat(seq: 1))
        #expect(owner.received == 1)
        #expect(attempt.phase == .cancelled)
        #expect(attempt.connection == nil)
        #expect(line.closes == [0])
    }
}

@MainActor
private final class RecordingOwner: ConnectionAttemptOwner {
    var current: ConnectionAttempt?
    var connected = 0
    var received = 0
    var events: [String] = []

    func isCurrent(_ attempt: ConnectionAttempt) -> Bool { current === attempt }
    func attempt(_ a: ConnectionAttempt, progress: String) {}
    func attempt(_ a: ConnectionAttempt, connected c: HostConnection, snapshot: TerminalSnapshot) {
        connected += 1
        events.append("connected")
    }
    func attempt(_ a: ConnectionAttempt, machines: [MachineView]) { events.append("machines") }
    func attempt(_ a: ConnectionAttempt, layout: HerdrAppLayout?) { events.append("layout") }
    func attempt(_ a: ConnectionAttempt, received message: EventMessage) async { received += 1 }
    func attempt(_ a: ConnectionAttempt, failed error: Error, retrying: Bool) {}
    func attemptFinished(_ a: ConnectionAttempt) {}
}
