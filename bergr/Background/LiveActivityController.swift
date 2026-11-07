import ActivityKit
import Foundation
import HerdrKit
import Observation
import UIKit
import WidgetKit

/// One machine's terminals, as the Live Activity sees them.
struct LiveActivityMachine {
    let host: UUID
    let name: String
    let terminals: [Terminal]
}

/// Shows the agents at a glance (Lock Screen + Dynamic Island) while the app is kept connected
/// in the background: starts when the app goes to the background with keep-alive on, follows the
/// sessions (at most every 2 s), ends on return to the foreground, keep-alive off, or nothing to show.
@MainActor
final class LiveActivityController {
    typealias State = BergrActivityAttributes.ContentState
    typealias Row = BergrActivityAttributes.Row

    static let maxRows = 3
    static let minInterval: TimeInterval = 2

    private static var retained: LiveActivityController?
    /// One line for RootView: creates and starts the controller once.
    static func run(sessions: SessionStore) {
        guard retained == nil else { return }
        let controller = LiveActivityController(sessions: sessions)
        retained = controller
        AnswerIntentBridge.handler = { [weak controller] request in await controller?.answer(request) }
        controller.start()
    }

    // MARK: Content (pure)

    nonisolated static func kind(of terminal: Terminal) -> String {
        switch ChatAgent.detect(terminal) {
        case .claude: "claude"
        case .codex: "codex"
        case .antigravity: "antigravity"
        case nil: "shell"
        }
    }

    /// Counts and the top rows (needs-you first, then working); nil when there is nothing to show.
    nonisolated static func content(machines: [LiveActivityMachine], screens: [String: [String]] = [:]) -> State? {
        var needs: [Row] = []
        var working: [Row] = []
        var ready: [Row] = []
        var done = 0
        for machine in machines {
            for terminal in machine.terminals where terminal.isLive {
                guard let state = terminal.agentState else { continue }
                switch state {
                case .needsYou, .error, .working:
                    let isNeeds = state != .working
                    let status = [terminal.status?.msg, terminal.status?.title]
                        .compactMap { $0 }.first { !$0.isEmpty }
                        ?? (isNeeds ? "Needs you" : "Working")
                    let row = Row(
                        kind: kind(of: terminal), title: terminal.displayName, status: status,
                        machine: machine.name, needsYou: isNeeds,
                        host: machine.host.uuidString, address: terminal.address)
                    if isNeeds { needs.append(row) } else { working.append(row) }
                case .done, .idle:
                    // A finished turn keeps its agent on the Lock Screen: it's waiting for your next message.
                    guard state == .done || ChatAgent.detect(terminal) != nil else { continue }
                    done += 1
                    let status = [terminal.status?.msg, terminal.status?.title]
                        .compactMap { $0 }.first { !$0.isEmpty } ?? "Ready"
                    ready.append(Row(
                        kind: kind(of: terminal), title: terminal.displayName, status: status,
                        machine: machine.name, needsYou: false,
                        host: machine.host.uuidString, address: terminal.address))
                }
            }
        }
        guard !needs.isEmpty || !working.isEmpty || done > 0 else { return nil }
        return State(
            needsYou: needs.count, working: working.count, done: done,
            rows: Array((needs + working + ready).prefix(maxRows)),
            prompt: PromptBuilder.prompt(machines: machines, screens: screens))
    }

    /// Identifies a blocked terminal's current question: a new status or turn is a new key.
    nonisolated static func screenKey(host: UUID, terminal: Terminal) -> String {
        [host.uuidString, terminal.address, terminal.status?.title ?? "", terminal.status?.msg ?? "",
         terminal.turn.map(String.init) ?? ""].joined(separator: "|")
    }

    /// `bergr://terminal?host=<uuid>&address=<t7>`
    nonisolated static func target(of url: URL) -> (host: UUID, address: String)? {
        guard url.scheme == "bergr", url.host == "terminal",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value.flatMap(UUID.init(uuidString:)),
              let address = items.first(where: { $0.name == "address" })?.value, !address.isEmpty
        else { return nil }
        return (host, address)
    }

    // MARK: Lifecycle

    let sessions: SessionStore
    private var started = false
    private var inBackground = false
    private var activity: Activity<BergrActivityAttributes>?
    private var lastSent: State?
    private var lastSentAt = Date.distantPast
    private var pending: Task<Void, Never>?
    /// Screens of blocked terminals (by `screenKey`), read headless, for the answer buttons.
    private var screens: [String: [String]] = [:]
    private var fetching: Set<String> = []
    private var lastSnapshot: AgentsSnapshot?

    init(sessions: SessionStore) { self.sessions = sessions }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inBackground = true; self?.reconcile() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inBackground = false; self?.reconcile() }
        }
        // Leftovers from a previous run (the app was killed while one was showing).
        for old in Activity<BergrActivityAttributes>.activities {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }
        observe()
        writeSnapshot()
    }

    private func machines() -> [LiveActivityMachine] {
        sessions.ids.compactMap { id in
            sessions.existing(id).map { LiveActivityMachine(host: id, name: $0.host.name, terminals: $0.terminals) }
        }
    }

    private func current() -> State? {
        guard KeepAlive.shared.enabled else { return nil }
        return Self.content(machines: machines(), screens: screens)
    }

    /// Writes the Home Screen widget's data and reloads it when it changed.
    private func writeSnapshot() {
        let snapshot = AgentsSnapshot(Self.content(machines: machines()), updated: .now)
        var previous = lastSnapshot
        previous?.updated = snapshot.updated
        guard previous != snapshot else { return }
        lastSnapshot = snapshot
        snapshot.save()
        WidgetCenter.shared.reloadTimelines(ofKind: BergrAppGroup.widgetKind)
    }

    /// Reads the screen of each blocked terminal we don't know yet (at most the visible few), and
    /// forgets the ones that are no longer blocked.
    private func prefetchScreens() {
        var wanted: Set<String> = []
        for machine in machines() {
            guard let session = sessions.existing(machine.host) else { continue }
            for terminal in machine.terminals where terminal.isLive && terminal.status?.state == "blocked" {
                let key = Self.screenKey(host: machine.host, terminal: terminal)
                wanted.insert(key)
                guard screens[key] == nil, !fetching.contains(key), wanted.count <= 6 else { continue }
                fetching.insert(key)
                Task { [weak self] in
                    let lines = await Self.readScreen(session: session, terminal: terminal)
                    guard let self else { return }
                    self.fetching.remove(key)
                    if let lines { self.screens[key] = lines; self.reconcile() }
                }
            }
        }
        screens = screens.filter { wanted.contains($0.key) }
    }

    /// After an answer (or a refused one): forget what we knew about that terminal and look again.
    func screenAnswered(host: String, address: String) {
        screens = screens.filter { !$0.key.hasPrefix("\(host)|\(address)|") }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.reconcile()
        }
    }

    private func observe() {
        withObservationTracking {
            _ = current()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observe()
                self.writeSnapshot()
                if self.inBackground { self.reconcile() }
            }
        }
    }

    private func reconcile() {
        pending?.cancel()
        pending = nil
        if inBackground, KeepAlive.shared.enabled { prefetchScreens() }
        guard inBackground, let state = current() else {
            end()
            return
        }
        if activity == nil {
            do {
                activity = try Activity.request(
                    attributes: BergrActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil), pushType: nil)
                lastSent = state
                lastSentAt = Date()
            } catch {
                activity = nil
            }
            return
        }
        guard state != lastSent else { return }
        let wait = Self.minInterval - Date().timeIntervalSince(lastSentAt)
        if wait > 0 {
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.reconcile()
            }
            return
        }
        lastSent = state
        lastSentAt = Date()
        let activity = activity
        Task { await activity?.update(ActivityContent(state: state, staleDate: nil)) }
    }

    private func end() {
        guard let activity else { return }
        self.activity = nil
        lastSent = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
