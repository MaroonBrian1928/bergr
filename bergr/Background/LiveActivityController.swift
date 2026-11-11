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
                    // Not when nobody has touched it for longer than the setting (Hide finished agents after).
                    guard state == .done || ChatAgent.detect(terminal) != nil, !QuietAgents.isQuiet(terminal) else { continue }
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

    /// What each machine's helper would post for the relay to sum, keyed by host id (the helper's
    /// `machine`): the per-machine counts `content` gives, and rows only in full mode. Seeded when
    /// the relay starts an activity, so a machine that stays quiet still counts toward the first push.
    nonisolated static func seed(machines: [LiveActivityMachine], fullContent: Bool) -> [String: Any] {
        var out: [String: Any] = [:]
        for machine in machines {
            let part = content(machines: [machine])
            var entry: [String: Any] = [
                "needsYou": part?.needsYou ?? 0, "working": part?.working ?? 0, "done": part?.done ?? 0,
            ]
            if fullContent {
                entry["rows"] = (part?.rows ?? []).map { row -> [String: Any] in
                    ["kind": row.kind, "title": row.title, "status": row.status, "machine": row.machine,
                     "needsYou": row.needsYou, "host": row.host, "address": row.address]
                }
            }
            out[machine.host.uuidString] = entry
        }
        return out
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
    let session = LiveActivitySession()
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
        // Leftovers from a previous run. One the machines update through the relay is theirs: iOS
        // can relaunch Bergr in the background after the phone locks, and ending it here closed it
        // the moment it appeared. It's adopted, and ends when Bergr is opened. Others (updated by
        // the app itself, now gone) end.
        let inForeground = UIApplication.shared.applicationState == .active
        for old in Activity<BergrActivityAttributes>.activities {
            if old.pushToken != nil, !inForeground, session.mode == .none {
                inBackground = true
                refreshSeed()
                session.adopt(LiveActivityHandle(old, note: Self.note), registration: registration)
                Self.note("adopted on launch")
            } else {
                Task { await old.end(nil, dismissalPolicy: .immediate) }
            }
        }
        observe()
        writeSnapshot()
    }

    private func machines() -> [LiveActivityMachine] {
        sessions.ids.compactMap { id in
            sessions.existing(id).map { LiveActivityMachine(host: id, name: $0.host.name, terminals: $0.terminals) }
        }
    }

    /// The Live Activity's settings for when Bergr isn't kept connected: updated by the machines
    /// through the push relay instead (Settings → Live Activity), showing counts only unless full
    /// content was chosen (that content passes through the relay and Apple readable).
    nonisolated static let pushKey = "bergr.liveActivity.push"
    nonisolated static let contentKey = "bergr.liveActivity.content"
    nonisolated static var pushEnabled: Bool { UserDefaults.standard.bool(forKey: pushKey) }
    nonisolated static var fullContent: Bool { UserDefaults.standard.string(forKey: contentKey) == "full" }

    /// Kept connected, the app updates the activity itself; otherwise the relay does, if set up.
    private var byPush: Bool {
        !KeepAlive.shared.enabled && Self.pushEnabled && PushRegistration.shared.relaySecret != nil
    }

    private func current() -> State? {
        // Settings → Live Activity, whichever way updates come.
        guard Self.pushEnabled else { return nil }
        if KeepAlive.shared.enabled { return Self.content(machines: machines(), screens: screens) }
        guard byPush, var state = Self.content(machines: machines()) else { return nil }
        // What the machines will send: no names or questions unless full content was chosen.
        state.prompt = nil
        if !Self.fullContent { state.rows = [] }
        return state
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
        if inBackground, KeepAlive.shared.enabled { prefetchScreens() }
        // Updated by push: once started it belongs to the machines and the relay (the session
        // ignores us). The app lets go of its machines in the background (they'd look empty).
        guard inBackground else {
            session.end(reason: "ended: Bergr opened")
            return
        }
        let pushed = byPush
        if session.mode == .none, pushed { refreshSeed() }
        session.show(current(), pushed: pushed, registration: registration)
    }

    /// The last few things that happened to the Live Activity, with times (Settings shows them
    /// under Live Activity): when one closes early, this says whether Bergr ended it or iOS did.
    nonisolated static let historyKey = "bergr.liveActivity.history"
    nonisolated static func note(_ what: String) {
        let line = Date.now.formatted(date: .omitted, time: .standard) + " " + what
        var lines = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
        lines.append(line)
        UserDefaults.standard.set(Array(lines.suffix(8)), forKey: historyKey)
    }

    // MARK: Updated through the relay

    /// The machines' counts as the activity shows them now, sent with the token (see `seed`).
    private var relaySeed: [String: Any] = [:]

    /// Only machines whose list is live: a paused or reconnecting one would seed zeros that its
    /// helper, seeing no change of its own, would never correct. Left out, it posts on its next change.
    private func refreshSeed() {
        let live = machines().filter { sessions.existing($0.host)?.state == .connected }
        relaySeed = Self.seed(machines: live, fullContent: Self.fullContent)
    }

    /// The POST body for the relay; the session adds the token.
    private func registration() -> [String: Any] {
        ["mode": Self.fullContent ? "full" : "counts", "hide_after": String(QuietAgents.seconds),
         "machines": relaySeed]
    }
}
