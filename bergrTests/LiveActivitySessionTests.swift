import Foundation
import Testing
@testable import bergr

@MainActor final class FakeHandle: ActivityHandle {
    let pushTokens: AsyncStream<Data>
    let tokens: AsyncStream<Data>.Continuation
    var updates: [BergrActivityAttributes.ContentState] = []
    var ended = 0

    init() { (pushTokens, tokens) = AsyncStream<Data>.makeStream() }

    func update(_ state: BergrActivityAttributes.ContentState) async { updates.append(state) }
    func end() async { ended += 1 }
}

@MainActor final class FakeRelay {
    var calls: [String] = []
    var bodies: [[String: Any]] = []
    /// Results for the next calls; true once they run out.
    var results: [Bool] = []
    private var gate: CheckedContinuation<Void, Never>?
    var gated = false
    var waiting = false

    func call(_ method: String, _ body: [String: Any]?) async -> Bool {
        calls.append(method)
        if let body { bodies.append(body) }
        if gated {
            waiting = true
            await withCheckedContinuation { gate = $0 }
            waiting = false
        }
        return results.isEmpty ? true : results.removeFirst()
    }

    func open() { gated = false; gate?.resume(); gate = nil }
}

@MainActor final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    private var sleepers: [Int: (deadline: Date, cont: CheckedContinuation<Void, Never>)] = [:]
    private var next = 0
    var sleeping: Int { sleepers.count }

    func sleep(_ d: Duration) async {
        let id = next
        next += 1
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        await withTaskCancellationHandler {
            await withCheckedContinuation { sleepers[id] = (now.addingTimeInterval(seconds), $0) }
        } onCancel: {
            Task { @MainActor in self.wake(id) }
        }
    }

    private func wake(_ id: Int) { sleepers.removeValue(forKey: id)?.cont.resume() }

    func advance(_ seconds: TimeInterval) async {
        now.addTimeInterval(seconds)
        for (id, s) in sleepers where s.deadline <= now { wake(id) }
        await settle()
    }
}

/// Lets the session's tasks run until they wait again.
@MainActor private func settle() async { for _ in 0..<60 { await Task.yield() } }

@MainActor final class Rig {
    let relay = FakeRelay()
    let clock = ManualClock()
    var handles: [FakeHandle] = []
    var notes: [String] = []
    var backgroundBegun = 0
    var backgroundReleased = 0
    var requested: [Bool] = []
    var requestFails = false
    var session: LiveActivitySession!

    init() {
        let env = LiveActivityEnvironment(
            request: { [unowned self] _, pushed in
                if requestFails { throw CocoaError(.fileNoSuchFile) }
                requested.append(pushed)
                let h = FakeHandle()
                handles.append(h)
                return h
            },
            relay: { [unowned self] m, b in await relay.call(m, b) },
            beginBackgroundTime: { [unowned self] in
                backgroundBegun += 1
                return { [unowned self] in backgroundReleased += 1 }
            },
            now: { [unowned self] in clock.now },
            sleep: { [unowned self] d in await clock.sleep(d) },
            note: { [unowned self] in notes.append($0) })
        session = LiveActivitySession(environment: env)
    }

    func state(_ n: Int) -> LiveActivitySession.State {
        .init(needsYou: n, working: 0, done: 0, rows: [])
    }

    func show(_ n: Int?, pushed: Bool = false) {
        session.show(n.map(state), pushed: pushed, registration: { ["mode": "counts"] })
    }

    func token(_ h: FakeHandle, _ byte: UInt8 = 1) async {
        h.tokens.yield(Data([byte]))
        await settle()
    }

    /// Starts a push activity and delivers its first token.
    func registered() async -> FakeHandle {
        show(1, pushed: true)
        let h = handles.last!
        await token(h)
        return h
    }
}

@MainActor struct LiveActivitySessionTests {
    let rig = Rig()

    @Test func relayFailureFallsBackToLocal() async {
        rig.relay.results = [false, false, false]
        rig.show(1, pushed: true)
        let h = rig.handles[0]
        #expect(rig.session.mode == .push(.awaitingToken))
        await rig.token(h)
        #expect(rig.session.mode == .push(.registering))
        await rig.clock.advance(2)
        await rig.clock.advance(5)
        #expect(rig.relay.calls == ["POST", "POST", "POST"])
        #expect(rig.session.mode == .local)
        #expect(rig.notes.contains("the relay didn't take it: updated by Bergr"))
        #expect(rig.backgroundReleased == 1)
        // Bergr updates it now, starting with the latest state it was given.
        #expect(h.updates == [rig.state(1)])
        await rig.clock.advance(3)
        rig.show(2)
        await settle()
        #expect(h.updates == [rig.state(1), rig.state(2)])
    }

    @Test func endWhileAwaitingTokenLeavesNothingBehind() async {
        rig.show(1, pushed: true)
        let h = rig.handles[0]
        await rig.session.end(reason: "ended: Bergr opened").value
        #expect(rig.session.mode == .none)
        #expect(h.ended == 1)
        #expect(rig.relay.calls.isEmpty)
        #expect(rig.backgroundBegun == 1 && rig.backgroundReleased == 1)
        await rig.token(h)   // a token that arrives now goes nowhere
        #expect(rig.relay.calls.isEmpty)
        #expect(rig.session.mode == .none)
    }

    @Test func endWhileRegisteringSendsDeleteAfterPost() async {
        rig.relay.gated = true
        rig.show(1, pushed: true)
        let h = rig.handles[0]
        await rig.token(h)
        #expect(rig.relay.waiting)
        let ending = rig.session.end(reason: "ended: Bergr opened")
        await settle()
        #expect(rig.relay.calls == ["POST"])   // DELETE waits for the POST
        #expect(h.ended == 0 || h.ended == 1)
        rig.relay.open()
        await ending.value
        #expect(rig.relay.calls == ["POST", "DELETE"])
        #expect(h.ended == 1)
        #expect(rig.session.mode == .none)
    }

    @Test func tokenAfterEndIsNotPosted() async {
        let h = await rig.registered()
        rig.relay.calls = []
        await rig.session.end(reason: "x").value
        await rig.token(h, 2)
        #expect(rig.relay.calls == ["DELETE"])
    }

    @Test func endBeforeAnyPostSendsNoDelete() async {
        rig.show(1, pushed: true)
        await rig.session.end(reason: "x").value
        #expect(!rig.relay.calls.contains("DELETE"))
        rig.show(1)
        await rig.session.end(reason: "y").value
        #expect(rig.relay.calls.isEmpty)
    }

    @Test func endWhenRegisteredSendsDelete() async {
        let h = await rig.registered()
        #expect(rig.session.mode == .push(.registered))
        #expect(rig.backgroundReleased == 1)
        #expect(rig.relay.bodies[0]["token"] as? String == "01")
        await rig.session.end(reason: "x").value
        #expect(rig.relay.calls == ["POST", "DELETE"])
        #expect(h.ended == 1)
    }

    @Test func pushModeIgnoresShowAndNil() async {
        let h = await rig.registered()
        rig.show(5, pushed: true)
        rig.show(nil)
        rig.show(6)
        await settle()
        #expect(rig.session.mode == .push(.registered))
        #expect(rig.session.ownedByRelay)
        #expect(h.updates.isEmpty)
        #expect(h.ended == 0)
        #expect(rig.handles.count == 1)
    }

    @Test func throttleCoalesces() async {
        rig.show(1)
        let h = rig.handles[0]
        rig.show(1)
        await settle()
        #expect(h.updates.isEmpty)   // same state: nothing
        rig.show(2)
        rig.show(3)
        await settle()
        #expect(h.updates.isEmpty)   // inside 2 s: deferred
        #expect(rig.clock.sleeping == 1)
        await rig.clock.advance(2)
        #expect(h.updates == [rig.state(3)])   // latest wins
        rig.show(4)
        await settle()
        #expect(h.updates.count == 1)   // throttled again after the update
        rig.show(nil)
        await settle()
        #expect(rig.session.mode == .none)
        #expect(h.ended == 1)
    }

    @Test func endCancelsDeferredUpdate() async {
        rig.show(1)
        let h = rig.handles[0]
        rig.show(2)
        await settle()
        await rig.session.end(reason: "x").value
        await rig.clock.advance(5)
        #expect(h.updates.isEmpty)
        #expect(h.ended == 1)
        #expect(rig.clock.sleeping == 0)
    }

    @Test func rotatedTokenReRegisters() async {
        let h = await rig.registered()
        await rig.token(h, 2)
        #expect(rig.relay.calls == ["POST", "POST"])
        #expect(rig.relay.bodies[1]["token"] as? String == "02")
        #expect(rig.session.mode == .push(.registered))
    }

    @Test func rotationFailureFallsBackAndStillDeletesOnEnd() async {
        let h = await rig.registered()
        rig.relay.results = [false, false, false]
        h.tokens.yield(Data([2]))
        await settle()
        await rig.clock.advance(2)
        await rig.clock.advance(5)
        #expect(rig.session.mode == .local)
        await rig.session.end(reason: "x").value
        #expect(rig.relay.calls.last == "DELETE")
        #expect(h.ended == 1)
    }

    @Test func replacementRegistrationCancelsOld() async {
        rig.show(1, pushed: true)
        let old = rig.handles[0]
        let new = FakeHandle()
        rig.session.adopt(new, registration: { ["mode": "counts"] })
        await settle()
        await rig.token(old, 1)
        #expect(rig.relay.calls.isEmpty)   // the old one's registration is gone
        await rig.token(new, 9)
        #expect(rig.relay.calls == ["POST"])
        #expect(rig.relay.bodies[0]["token"] as? String == "09")
        #expect(old.ended == 1)
    }

    @Test func adoptStartsInAwaitingToken() async {
        let h = FakeHandle()
        rig.session.adopt(h, registration: { ["mode": "counts"] })
        #expect(rig.session.mode == .push(.awaitingToken))
        #expect(rig.backgroundBegun == 1)
        #expect(rig.relay.calls.isEmpty)
        await rig.token(h)
        #expect(rig.session.mode == .push(.registered))
        #expect(rig.backgroundReleased == 1)
    }
}
