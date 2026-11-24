import Foundation
import HerdrKit
import Observation
import UserNotifications

/// Watches every session and posts a local notification when an agent needs the user, hits an
/// error or finishes.
@MainActor
final class AgentNotifier {
    enum Kind: String {
        case needsYou, finished, error

        /// Ordinary alerts when the user has to act, passive for a finished agent.
        var interruptionLevel: UNNotificationInterruptionLevel { self == .finished ? .passive : .active }
    }

    struct Alert: Equatable {
        let host: UUID
        let address: String
        let kind: Kind
        let title: String
        let body: String
        /// The question, when it is known from the status alone (a permission prompt): answer buttons.
        var question: AnswerQuestion?
        /// host + address + turn/statusMs: one alert per transition.
        let key: String
    }

    /// Yes / No for a permission prompt, the one question the status alone describes reliably (the
    /// same rule as bergr-notify); other questions have their options only on the screen.
    nonisolated static func question(for status: TerminalStatus?) -> AnswerQuestion? {
        guard status?.state == "blocked", status?.kind == "permission" else { return nil }
        // A dangerous command gets no approve buttons.
        guard DangerousCommand.check([status?.msg, status?.title].compactMap { $0 }.joined(separator: "\n")) == nil
        else { return nil }
        let title = [status?.msg, status?.title].compactMap { $0 }.first { !$0.isEmpty } ?? "Needs approval"
        return AnswerQuestion(title: title, options: ["Yes", "No"], keys: true)
    }

    /// Alerts for terminals that moved to blocked ("needs you"), to error, or to an unread done
    /// ("finished") between `old` and `new`; titles end in " on <machine>" when `machine` is given.
    /// Terminals not in `old` are a first look, not a transition.
    nonisolated static func alerts(
        host: UUID, old: [Terminal], new: [Terminal],
        focused: String? = nil, delivered: Set<String> = [], machine: String? = nil
    ) -> [Alert] {
        let before = Dictionary(old.map { ($0.address, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Alert] = []
        for terminal in new {
            guard terminal.isLive, terminal.address != focused,
                  let old = before[terminal.address], let state = terminal.status?.state else { continue }
            // A change of state, or a done that became unread: "done" can arrive before the turn
            // goes up, and then looks already read until it does, with the state word unchanged.
            let becameUnread = state == "done" && old.status?.state == "done"
                && old.agentState != .done && terminal.agentState == .done
            guard state != old.status?.state || becameUnread else { continue }
            let kind: Kind
            switch state {
            case "blocked": kind = .needsYou
            case "error": kind = .error
            // Same "unread" rule as the list: done and not yet seen (herdr.seen vs turn).
            case "done" where terminal.agentState == .done: kind = .finished
            default: continue
            }
            let key = "\(host.uuidString)|\(terminal.address)|\(terminal.turn ?? 0)|\(terminal.statusMs ?? 0)|\(kind.rawValue)"
            guard !delivered.contains(key) else { continue }
            let name = terminal.displayName
            let body = [terminal.status?.title, terminal.status?.msg].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            var title = switch kind {
            case .needsYou: "\(name) needs you"
            case .error: "\(name) hit an error"
            case .finished: "\(name) is done"
            }
            if let machine, !machine.isEmpty { title += " on \(machine)" }
            result.append(Alert(
                host: host, address: terminal.address, kind: kind, title: title, body: body,
                question: kind == .needsYou ? question(for: terminal.status) : nil, key: key))
        }
        return result
    }

    private let sessions: SessionStore
    private var last: [UUID: [Terminal]] = [:]
    private var delivered: Set<String> = []
    /// What the relay last heard from each machine's helper and when it was asked, refreshed at
    /// most every 5 minutes; `heardFetch` is a refresh under way, shared by alerts that arrive together.
    private var heard: (value: RelayHeard, at: Date)?
    private var heardFetch: Task<RelayHeard?, Never>?
    private var started = false
    var focusedAddress: (host: UUID, address: String)? {
        didSet { NotificationRouter.shared.focused = focusedAddress }
    }

    init(sessions: SessionStore) { self.sessions = sessions }

    func start() {
        guard !started else { return }
        started = true
        observe()
    }

    private func observe() {
        let current = withObservationTracking {
            let all = sessions.ids.compactMap { sessions.existing($0) }
            return all.map { session in
                (id: session.host.id, hasSnapshot: session.snapshot != nil,
                 terminals: Self.withoutDirectCopies(session, among: all),
                 machine: session.host.name.isEmpty ? session.host.target.host : session.host.name)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for item in current where item.hasSnapshot {
            if let old = last[item.id] {
                let focus = focusedAddress.flatMap { $0.host == item.id ? $0.address : nil }
                for alert in Self.alerts(host: item.id, old: old, new: item.terminals, focused: focus, delivered: delivered, machine: item.machine) {
                    delivered.insert(alert.key)
                    let agent = item.terminals.first { $0.address == alert.address }?.displayName ?? "Agent"
                    let transcript = sessions.existing(item.id)?.runningFeed(address: alert.address)
                        .map { NotificationSummary.transcript($0.items) } ?? []
                    post(alert, agent: agent, transcript: transcript)
                }
            }
            last[item.id] = item.terminals
        }
        let ids = Set(current.map(\.id))
        for id in last.keys where !ids.contains(id) { last[id] = nil }
    }

    /// A session's terminals, less those of machines linked through it that are also added
    /// directly: those alert from the direct connection only (they alerted twice, once each way).
    private static func withoutDirectCopies(_ session: HostSession, among all: [HostSession]) -> [Terminal] {
        let direct = all.filter { $0.host.id != session.host.id }.reduce(into: SameMachine.DirectIdentity()) { names, other in
            var failed = false
            if case .failed = other.state { failed = true }
            names.formUnion(SameMachine.directNames(other.host, coreName: other.coreName, failed: failed,
                                                        resolve: AddressResolver.shared.ips))
        }
        func machine(_ t: Terminal) -> String? {
            t.address.firstIndex(of: "/").map { String(t.address[..<$0]) }
        }
        let skip = SameMachine.linkedAlsoDirect(session.machines, names: Set(session.terminals.compactMap(machine)),
                                                direct: direct, resolve: AddressResolver.shared.ips)
        return skip.isEmpty ? session.terminals : session.terminals.filter { machine($0).map { !skip.contains($0) } ?? true }
    }

    private func post(_ alert: Alert, agent: String, transcript: [String]) {
        // Settings → Notifications.
        guard Delivery.notificationsHere else { return }
        // A machine whose helper pushes to this phone gets its alert from there: posting here too
        // gave two of each while Bergr was open or still running in the background.
        if Delivery.helperSupported, PushRegistration.shared.enabled, let secret = PushRegistration.shared.relaySecret {
            Task { @MainActor in
                if await self.helperPushes(for: alert.host, secret: secret) { return }
                self.postNow(alert, agent: agent, transcript: transcript)
            }
            return
        }
        postNow(alert, agent: agent, transcript: transcript)
    }

    /// Whether the relay heard this machine's helper recently (within its stale limit), counting
    /// the time since it was asked.
    private func helperPushes(for host: UUID, secret: String) async -> Bool {
        if heard == nil || Date().timeIntervalSince(heard!.at) > 5 * 60 {
            let fetch = heardFetch ?? Task { await PushRegistration.fetchHeard(secret: secret) }
            heardFetch = fetch
            let asked = Date()
            let value = await fetch.value
            if heardFetch == fetch { heardFetch = nil }
            // A failed refresh keeps the last good answer (it ages out by itself).
            if let value, heard.map({ $0.at < asked }) ?? true { heard = (value, asked) }
        }
        guard let heard, let age = heard.value.age(of: host) else { return false }
        return Self.helperCovers(age: age + Date().timeIntervalSince(heard.at))
    }

    /// A helper heard within `RelayHeard.staleAfter` sends this machine's alerts itself.
    nonisolated static func helperCovers(age: TimeInterval?) -> Bool {
        guard let age else { return false }
        return age <= RelayHeard.staleAfter
    }

    private func postNow(_ alert: Alert, agent: String, transcript: [String]) {
        guard Delivery.notificationsHere else { return }
        // Per-kind switches, muted agents and quiet hours.
        guard NotificationPrefs.load().allows(kind: alert.kind, host: alert.host, address: alert.address,
                                              minute: NotificationPrefs.minute(of: Date())) else { return }
        // The body is the model's one-sentence summary of the chat when there is one (within
        // NotificationSummary.timeout), else the status text.
        Task { @MainActor in
            let body = await NotificationSummary.body(
                agent: agent, kind: alert.kind, transcript: transcript, fallback: alert.body,
                writer: OnDeviceText.shared)
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = body
            content.sound = .default
            content.interruptionLevel = alert.kind.interruptionLevel
            content.threadIdentifier = alert.host.uuidString
            content.userInfo = ["host": alert.host.uuidString, "address": alert.address]
            if let q = alert.question, let category = AnswerCategory.identifier(for: q) {
                content.categoryIdentifier = category
                content.userInfo.merge(AnswerCategory.userInfo(q)) { _, new in new }
            } else if alert.kind != .error, let category = AnswerCategory.replyIdentifier {
                content.categoryIdentifier = category
            }
            let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            await ConversationAlerts.removeSuperseded(by: content.userInfo, keeping: alert.key)
        }
    }
}
