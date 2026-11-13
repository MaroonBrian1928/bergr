import Foundation
import SwiftUI
import UserNotifications

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
    private var fired: [String: Double]
    private var latest: [String: Double]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
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
            alerts.append(UsageAlert(key: key, body: Self.body(reading: candidate.reading, kind: candidate.kind, window: candidate.window)))
        }
        if oldFired != fired { defaults?.set(fired, forKey: Self.storageKey) }
        if oldLatest != latest { defaults?.set(latest, forKey: Self.storageKey + ".latest") }
        return alerts
    }

    static func body(reading: UsageReading, kind: String, window: ChatFeed.Usage.Window) -> String {
        var text = "\(reading.agent.displayName) on \(reading.machine): \(kind) limit at \(Int(window.percent.rounded()))%"
        if let resets = window.resetsAt {
            text += ", resets \(resets.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
        }
        return text
    }
}

/// Posts the alerts as local notifications, when Settings → Notifications is on.
@MainActor
enum UsageNotifications {
    static func post(_ alerts: [UsageAlert]) {
        guard UserDefaults.standard.bool(forKey: Delivery.notificationsKey) else { return }
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

/// Watches the readings and posts a notification when a plan window crosses the threshold.
/// Attach it once at the app's root, so the alerts come whichever screen is open.
struct UsageAlertsModifier: ViewModifier {
    let readings: [UsageReading]
    @State private var tracker = UsageAlertTracker()

    func body(content: Content) -> some View {
        content
            .onAppear { UsageNotifications.post(tracker.alerts(for: readings)) }
            .onChange(of: readings) { _, new in UsageNotifications.post(tracker.alerts(for: new)) }
    }
}


/// Watches every running feed's usage for the 80% alerts, in a view of its own so a usage update
/// only re-runs this, not the root view it sits behind.
struct UsageAlertsHost: View {
    let sessions: SessionStore
    @Environment(HostStore.self) private var hosts

    var body: some View {
        Color.clear
            .modifier(UsageAlertsModifier(readings: UsageReadings.readings(hosts: hosts.hosts, sessions: sessions)))
            .accessibilityHidden(true)
    }
}
