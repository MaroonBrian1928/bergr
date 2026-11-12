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

        /// Time-sensitive when the user has to act, passive for a finished agent.
        var interruptionLevel: UNNotificationInterruptionLevel { self == .finished ? .passive : .timeSensitive }
    }

    struct Alert: Equatable {
        let host: UUID
        let address: String
        let kind: Kind
        let title: String
        let body: String
        /// host + address + turn/statusMs: one alert per transition.
        let key: String
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
            result.append(Alert(host: host, address: terminal.address, kind: kind, title: title, body: body, key: key))
        }
        return result
    }

    private let sessions: SessionStore
    private var last: [UUID: [Terminal]] = [:]
    private var delivered: Set<String> = []
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
            sessions.ids.compactMap { id in
                sessions.existing(id).map { (id: id, hasSnapshot: $0.snapshot != nil, terminals: $0.terminals,
                         machine: $0.host.name.isEmpty ? $0.host.target.host : $0.host.name) }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for item in current where item.hasSnapshot {
            if let old = last[item.id] {
                let focus = focusedAddress.flatMap { $0.host == item.id ? $0.address : nil }
                for alert in Self.alerts(host: item.id, old: old, new: item.terminals, focused: focus, delivered: delivered, machine: item.machine) {
                    delivered.insert(alert.key)
                    post(alert)
                }
            }
            last[item.id] = item.terminals
        }
        let ids = Set(current.map(\.id))
        for id in last.keys where !ids.contains(id) { last[id] = nil }
    }

    private func post(_ alert: Alert) {
        // Settings → Notifications.
        guard UserDefaults.standard.bool(forKey: Delivery.notificationsKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        content.interruptionLevel = alert.kind.interruptionLevel
        content.threadIdentifier = alert.host.uuidString
        content.userInfo = ["host": alert.host.uuidString, "address": alert.address]
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
