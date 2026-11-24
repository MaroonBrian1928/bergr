import Foundation
import SwiftUI
import UserNotifications
#if os(iOS)
import WidgetKit
#endif

/// A plan window that reached the threshold: the notification's text and its identity.
struct UsageAlert: Equatable {
    /// The window's identity (agent, session or weekly, reset time): one alert per window.
    let key: String
    let body: String
}

/// Alerts once per unexpired plan window, using the newest trustworthy snapshot. Replayed
/// transcripts, conflicting sessions, percentage corrections and relaunches must not re-arm it.
@MainActor
final class UsageAlertTracker {
    static let threshold = 80.0
    static let maximumCodexAge: TimeInterval = 15 * 60
    static let storageKey = "usageAlerts.windows.v2"

    private let defaults: UserDefaults?
    private let history: UsageHistory?
    private var fired: [String: Double]
    private var latest: [String: Double]

    init(defaults: UserDefaults? = .standard, history: UsageHistory? = nil) {
        self.defaults = defaults
        self.history = history
        fired = defaults?.dictionary(forKey: Self.storageKey) as? [String: Double] ?? [:]
        latest = defaults?.dictionary(forKey: Self.storageKey + ".latest") as? [String: Double] ?? [:]
    }

    func alerts(for readings: [UsageReading], now: Date = .now) -> [UsageAlert] {
        // Multiple Mac windows can own trackers initialized before either one alerts.
        // Merge the shared ledger on every pass, not just at initialization.
        if let saved = defaults?.dictionary(forKey: Self.storageKey) as? [String: Double] {
            fired.merge(saved) { max($0, $1) }
        }
        if let saved = defaults?.dictionary(forKey: Self.storageKey + ".latest") as? [String: Double] {
            latest.merge(saved) { max($0, $1) }
        }
        let oldFired = fired, oldLatest = latest
        let instant = now.timeIntervalSince1970
        fired = fired.filter { $0.value.isFinite && $0.value > instant }
        latest = latest.filter { entry in
            guard let suffix = entry.key.split(separator: "|").last,
                  let reset = Double(suffix) else { return false }
            return reset > instant && entry.value.isFinite
        }
        struct Candidate {
            let reading: UsageReading
            let kind: String
            let window: ChatFeed.Usage.Window
            let observed: Double?
        }
        var order: [String] = []
        var candidates: [String: Candidate] = [:]
        for reading in readings {
            guard reading.running, let usage = reading.usage else { continue }
            let observed = usage.observedAt?.timeIntervalSince1970
            if reading.agent == .codex {
                // Old helpers have no timestamp: they cannot prove that a rate-limit warning
                // is current. Allow a minute of clock skew, never stale transcript history.
                guard let observed, observed.isFinite, instant - observed <= Self.maximumCodexAge,
                      observed - instant <= 60 else { continue }
            }
            let windows = [("session", usage.session), ("weekly", usage.weekly)]
            for (kind, value) in windows {
                guard let window = value, window.percent.isFinite, (0...100).contains(window.percent),
                      let reset = window.resetsAt?.timeIntervalSince1970,
                      reset.isFinite, reset > instant, reset < Double(Int.max) else { continue }
                let key = "\(reading.agent.rawValue)|\(kind)|\(Int(reset))"
                if let observed, let previous = latest[key], observed < previous { continue }
                let candidate = Candidate(reading: reading, kind: kind, window: window, observed: observed)
                if let previous = candidates[key] {
                    let before = previous.observed ?? -.infinity, after = observed ?? -.infinity
                    if after < before || (after == before && window.percent <= previous.window.percent) { continue }
                } else {
                    order.append(key)
                }
                candidates[key] = candidate
            }
        }
        var alerts: [UsageAlert] = []
        for key in order {
            guard let candidate = candidates[key] else { continue }
            if let observed = candidate.observed { latest[key] = observed }
            guard candidate.window.percent >= Self.threshold, fired[key] == nil else { continue }
            fired[key] = candidate.window.resetsAt!.timeIntervalSince1970
            let suffix = history.flatMap { history -> String? in
                let historyKey = UsageHistory.key(machine: candidate.reading.machine,
                                                  agent: candidate.reading.agent.rawValue, kind: candidate.kind)
                return history.forecast(key: historyKey, window: candidate.window, now: now).alertSuffix(now: now)
            }
            alerts.append(UsageAlert(key: key, body: Self.body(reading: candidate.reading, kind: candidate.kind,
                                                               window: candidate.window, forecast: suffix)))
        }
        if oldFired != fired { defaults?.set(fired, forKey: Self.storageKey) }
        if oldLatest != latest { defaults?.set(latest, forKey: Self.storageKey + ".latest") }
        return alerts
    }

    static func body(reading: UsageReading, kind: String, window: ChatFeed.Usage.Window,
                     forecast: String? = nil) -> String {
        var text = "\(reading.agent.displayName) on \(reading.machine): \(kind) limit at \(Int(window.percent.rounded()))%"
        if let resets = window.resetsAt {
            text += ", resets \(resets.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        if let forecast { text += ", \(forecast)" }
        return text
    }
}

/// A context window that crossed 90%: the notification's text and where it came from.
struct ContextAlert: Equatable {
    /// The reading's id, "<host id>/<terminal address>".
    let id: String
    let body: String
}

/// Alerts once per crossing of 90% context for each agent session, re-armed below 70%
/// (after a compaction). Held in memory: a relaunch at a high context alerts again once.
@MainActor
final class ContextAlertTracker {
    private var armed: [String: Bool] = [:]

    func alerts(for readings: [UsageReading]) -> [ContextAlert] {
        var alerts: [ContextAlert] = []
        var seen = Set<String>()
        for reading in readings {
            seen.insert(reading.id)
            guard let fraction = reading.usage?.fraction else { continue }
            let isArmed = armed[reading.id] ?? true
            if fraction >= ContextWarning.threshold {
                guard isArmed else { continue }
                armed[reading.id] = false
                alerts.append(ContextAlert(id: reading.id, body: Self.body(reading: reading, fraction: fraction)))
            } else if fraction < ContextWarning.rearm {
                armed[reading.id] = true
            }
        }
        armed = armed.filter { seen.contains($0.key) }
        return alerts
    }

    static func body(reading: UsageReading, fraction: Double) -> String {
        "\(reading.agent.displayName) on \(reading.machine) is at \(Int((fraction * 100).rounded()))% context"
    }

    /// The host and terminal address out of a reading id.
    static func parts(of id: String) -> (host: UUID, address: String)? {
        guard let slash = id.firstIndex(of: "/"), let host = UUID(uuidString: String(id[..<slash])) else { return nil }
        return (host, String(id[id.index(after: slash)...]))
    }
}

/// Posts the alerts as local notifications, when Settings → Notifications is on.
@MainActor
enum UsageNotifications {
    static func post(_ alerts: [UsageAlert]) {
        guard Delivery.notificationsHere else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = "Usage"
            content.body = alert.body
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "usage-\(alert.key)", content: content, trigger: nil))
        }
    }
}

extension UsageNotifications {
    /// A context warning is an "Errors"-kind notification: the same switch, muted agents and quiet hours.
    static func post(_ alerts: [ContextAlert]) {
        guard Delivery.notificationsHere else { return }
        let prefs = NotificationPrefs.load()
        for alert in alerts {
            guard let (host, address) = ContextAlertTracker.parts(of: alert.id),
                  prefs.allows(kind: .error, host: host, address: address,
                               minute: NotificationPrefs.minute(of: Date())) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Context"
            content.body = alert.body
            content.sound = .default
            content.threadIdentifier = host.uuidString
            content.userInfo = ["host": host.uuidString, "address": address]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "context-\(alert.id)-\(Int(Date().timeIntervalSince1970))",
                                      content: content, trigger: nil))
        }
    }
}

/// Watches the readings and posts a notification when a plan window crosses the threshold.
/// Attach it once at the app's root, so the alerts come whichever screen is open.
struct UsageAlertsModifier: ViewModifier {
    let readings: [UsageReading]
    @State private var tracker = UsageAlertTracker(history: .shared)
    @State private var contextTracker = ContextAlertTracker()

    func body(content: Content) -> some View {
        content
            .onAppear { check(readings) }
            .onChange(of: readings) { _, new in check(new) }
    }

    private func check(_ readings: [UsageReading]) {
        // The readings come from the live feeds and the probe: record them (throttled), then alert.
        UsageHistory.shared.record(readings)
        publishSnapshot(readings)
        UsageNotifications.post(tracker.alerts(for: readings))
        UsageNotifications.post(contextTracker.alerts(for: readings))
    }

    /// The Usage widget's data, written when it changes.
    private func publishSnapshot(_ readings: [UsageReading]) {
        let snapshot = UsageSnapshot.make(readings: readings, history: .shared)
        guard !snapshot.windows.isEmpty, UsageSnapshot.load().windows != snapshot.windows else { return }
        snapshot.save()
        #if os(iOS)
        WidgetCenter.shared.reloadTimelines(ofKind: UsageSnapshot.widgetKind)
        #endif
    }
}


/// Watches every running feed's usage for the 80% alerts, in a view of its own so a usage update
/// only re-runs this, not the root view it sits behind.
struct UsageAlertsHost: View {
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            // Not the demo machines: their made-up numbers never alert, reach the widget or the saved history.
            .modifier(UsageAlertsModifier(readings: UsageReadings.readings(hosts: hosts.hosts.filter { !$0.isDemo }, sessions: sessions)))
            .accessibilityHidden(true)
            // While the app is active, read working agents without an open chat now and then; the
            // probe itself keeps each agent to one read per five minutes.
            .task(id: scenePhase == .active) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    await UsageProbe.shared.refresh(UsageReadings.targets(hosts: hosts.hosts, sessions: sessions),
                                                    minAge: UsageProbe.pollInterval, onlyWorking: true)
                    try? await Task.sleep(for: .seconds(30))
                }
            }
    }
}
