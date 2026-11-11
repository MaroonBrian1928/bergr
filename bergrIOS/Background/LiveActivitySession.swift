import ActivityKit
import Foundation
import UIKit

/// The one Live Activity, as the session sees it (a fake in tests).
@MainActor protocol ActivityHandle: AnyObject {
    var pushTokens: AsyncStream<Data> { get }
    func update(_ state: BergrActivityAttributes.ContentState) async
    func end() async
}

/// Wraps the real activity; also notes iOS ending it in the history (see `LiveActivityController.note`).
@MainActor final class LiveActivityHandle: ActivityHandle {
    private let activity: Activity<BergrActivityAttributes>
    private var watcher: Task<Void, Never>?

    init(_ activity: Activity<BergrActivityAttributes>, note: @escaping (String) -> Void) {
        self.activity = activity
        watcher = Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                note(state == .dismissed ? "dismissed by iOS or from the Lock Screen" : "ended by iOS")
            }
        }
    }

    var pushTokens: AsyncStream<Data> {
        let updates = activity.pushTokenUpdates
        return AsyncStream { continuation in
            let forward = Task {
                for await token in updates { continuation.yield(token) }
                continuation.finish()
            }
            continuation.onTermination = { _ in forward.cancel() }
        }
    }

    func update(_ state: BergrActivityAttributes.ContentState) async {
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    func end() async {
        watcher?.cancel()   // our own end isn't "ended by iOS"
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}

struct LiveActivityEnvironment {
    var request: @MainActor (_ state: LiveActivitySession.State, _ pushed: Bool) throws -> any ActivityHandle
    var relay: @MainActor (_ method: String, _ body: [String: Any]?) async -> Bool
    /// Starts background time; the result gives it back (idempotent).
    var beginBackgroundTime: @MainActor () -> (@MainActor () -> Void)
    var now: @MainActor () -> Date = { .now }
    var sleep: @MainActor (Duration) async -> Void
    var note: (String) -> Void = LiveActivityController.note

    static var live: LiveActivityEnvironment {
        LiveActivityEnvironment(
            request: { state, pushed in
                let activity = try Activity.request(
                    attributes: BergrActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil), pushType: pushed ? .token : nil)
                return LiveActivityHandle(activity, note: LiveActivityController.note)
            },
            relay: { method, body in
                guard let secret = PushRegistration.shared.relaySecret else { return false }
                var request = URLRequest(url: PushRegistration.relayURL.appending(path: "v1/activity"))
                request.httpMethod = method
                request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                }
                let status = (try? await URLSession.shared.data(for: request))
                    .flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
                return status.map { (200..<300).contains($0) } ?? false
            },
            beginBackgroundTime: {
                let app = UIApplication.shared
                var id = UIBackgroundTaskIdentifier.invalid
                id = app.beginBackgroundTask { if id != .invalid { app.endBackgroundTask(id); id = .invalid } }
                return { if id != .invalid { app.endBackgroundTask(id); id = .invalid } }
            },
            sleep: { try? await Task.sleep(for: $0) })
    }
}

/// Owns the one Live Activity: its mode (none, updated by Bergr, or by the relay and how far its
/// registration is), the update throttle and the ordered cleanup. Nothing else touches the activity.
@MainActor
final class LiveActivitySession {
    typealias State = BergrActivityAttributes.ContentState
    enum Push: Equatable { case awaitingToken, registering, registered }
    enum Mode: Equatable { case none, local, push(Push) }

    private(set) var mode: Mode = .none
    /// The relay updates it (and Bergr ends it back in the foreground); Bergr leaves it alone.
    var ownedByRelay: Bool { if case .push = mode { true } else { false } }

    private let env: LiveActivityEnvironment
    private let minInterval: TimeInterval
    private let registerBackoff: [Duration]

    private var handle: (any ActivityHandle)?
    private var lastSent: State?
    private var lastSentAt = Date.distantPast
    /// The newest state asked for, for the timer and for falling back from the relay.
    private var latest: State?
    private var timer: Task<Void, Never>?
    private var registration: Task<Void, Never>?
    private var releaseBackground: (@MainActor () -> Void)?
    /// A POST was started for this activity: ending it has to DELETE, after that POST finished.
    private var postStarted = false
    /// Updates run one after another; ending waits for them.
    private var updates: Task<Void, Never>?

    init(environment: LiveActivityEnvironment = .live, minInterval: TimeInterval = 2,
         registerBackoff: [Duration] = [.zero, .seconds(2), .seconds(5)]) {
        env = environment
        self.minInterval = minInterval
        self.registerBackoff = registerBackoff
    }

    func show(_ state: State?, pushed: Bool, registration body: @escaping @MainActor () -> [String: Any]) {
        if let state { latest = state }
        switch mode {
        case .push:
            return   // the relay owns it, and the app lets go of its machines in the background
        case .none:
            guard let state else { return }
            let started: any ActivityHandle
            do { started = try env.request(state, pushed) } catch { return }
            handle = started
            lastSent = state
            lastSentAt = env.now()
            if pushed {
                mode = .push(.awaitingToken)
                env.note("started, updated by the machines")
                listen(to: started, body: body)
            } else {
                mode = .local
                env.note("started, updated by Bergr")
            }
        case .local:
            guard let state else {
                end(reason: "ended in the background (nothing to show)")
                return
            }
            timer?.cancel()
            timer = nil
            apply(state)
        }
    }

    /// Takes an activity left from a previous run that the relay updates.
    func adopt(_ adopted: any ActivityHandle, registration body: @escaping @MainActor () -> [String: Any]) {
        timer?.cancel()
        timer = nil
        if let old = handle, old !== adopted { Task { await old.end() } }
        handle = adopted
        lastSent = nil
        mode = .push(.awaitingToken)
        listen(to: adopted, body: body)
    }

    /// Ends the activity and, if the relay may know it, tells the relay, after everything in flight.
    @discardableResult
    func end(reason: String) -> Task<Void, Never> {
        guard mode != .none else { return Task {} }
        env.note(reason)
        timer?.cancel()
        let registering = registration
        registering?.cancel()
        let ending = handle
        let delete = postStarted
        let queued = updates
        mode = .none
        handle = nil
        lastSent = nil
        latest = nil
        timer = nil
        registration = nil
        updates = nil
        postStarted = false
        giveBackBackgroundTime()
        return Task { @MainActor [env] in
            await queued?.value
            await registering?.value
            await ending?.end()
            if delete { _ = await env.relay("DELETE", nil) }
        }
    }

    // MARK: Updated by Bergr

    private func apply(_ state: State) {
        guard state != lastSent else { return }
        let wait = minInterval - env.now().timeIntervalSince(lastSentAt)
        if wait > 0 {
            timer = Task { @MainActor [weak self] in
                await self?.env.sleep(.seconds(wait))
                guard !Task.isCancelled, let self, self.mode == .local, let state = self.latest else { return }
                self.timer = nil
                self.apply(state)
            }
            return
        }
        lastSent = state
        lastSentAt = env.now()
        guard let handle else { return }
        let previous = updates
        updates = Task { @MainActor in
            await previous?.value
            await handle.update(state)
        }
    }

    // MARK: Updated through the relay

    private func giveBackBackgroundTime() {
        releaseBackground?()
        releaseBackground = nil
    }

    /// Hands each push token to the relay as soon as iOS gives it, with the background time the app
    /// gets to finish that; the machines' helpers then keep it current.
    private func listen(to listened: any ActivityHandle, body: @escaping @MainActor () -> [String: Any]) {
        giveBackBackgroundTime()
        releaseBackground = env.beginBackgroundTime()
        let previous = registration
        previous?.cancel()
        registration = Task { @MainActor [weak self] in
            await previous?.value   // an old POST in flight finishes before the new one starts
            for await data in listened.pushTokens {
                guard let self, !Task.isCancelled else { return }
                self.mode = .push(.registering)
                var payload = body()
                payload["token"] = PushRegistration.hex(data)
                // A blip shouldn't cost the Lock Screen: try again shortly.
                var posted = false
                for wait in self.registerBackoff {
                    if wait > .zero { await self.env.sleep(wait) }
                    if Task.isCancelled { return }
                    self.postStarted = true
                    posted = await self.env.relay("POST", payload)
                    if Task.isCancelled { return }
                    if posted { break }
                }
                guard posted else {
                    self.fallBackToLocal()
                    return
                }
                self.mode = .push(.registered)
                self.giveBackBackgroundTime()
            }
        }
    }

    /// The relay didn't take it: Bergr updates the activity itself.
    private func fallBackToLocal() {
        env.note("the relay didn't take it: updated by Bergr")
        mode = .local
        registration = nil
        giveBackBackgroundTime()
        lastSent = nil
        if let latest { apply(latest) }
    }
}
