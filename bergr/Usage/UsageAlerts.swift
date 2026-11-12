import Foundation
import SwiftUI
import UserNotifications

/// A plan window that reached the threshold: the notification's text and its identity.
struct UsageAlert: Equatable {
    /// The window's identity (agent, session or weekly, reset time): one alert per window.
    let key: String
    let body: String
}

/// Decides which plan windows just crossed the threshold. A window is armed again when its percent
/// falls back under the threshold or it gets a new reset time.
@MainActor
final class UsageAlertTracker {
    static let threshold = 80.0

    private var fired: Set<String> = []

    func alerts(for readings: [UsageReading]) -> [UsageAlert] {
        var alerts: [UsageAlert] = []
        for reading in readings {
            guard let usage = reading.usage else { continue }
            let windows: [(kind: String, window: ChatFeed.Usage.Window?)] = [("session", usage.session), ("weekly", usage.weekly)]
            for (kind, window) in windows {
                guard let window else { continue }
                // The window's identity is its reset time: the percent climbs within one window.
                let resets = window.resetsAt.map { Int($0.timeIntervalSince1970) } ?? 0
                let key = "\(reading.agent.rawValue)|\(kind)|\(resets)"
                guard window.percent >= Self.threshold else {
                    fired.remove(key)
                    continue
                }
                guard fired.insert(key).inserted else { continue }
                alerts.append(UsageAlert(key: key, body: Self.body(reading: reading, kind: kind, window: window)))
            }
        }
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
