import AppKit
import HerdrKit
import UserNotifications

/// macOS notifications (plan 2.8, option A): local alerts from the live sessions, no APNs and no
/// helper on the machines. `AgentNotifier` decides what alerts (the same code as iOS); this only
/// starts it, asks for permission, and routes a click to the agent's window.
///
/// Wiring (chunk A owns the app and window files):
/// - `start(sessions:)` once in `BergrMacApp.init`, so a click that launches the app is delivered.
/// - `authorize()` when the Notifications switch in Settings turns on (`start` asks only if it is on).
/// - `focus(_:)` with the agent of the key window while the app is active, nil otherwise, so the chat
///   on screen doesn't alert about itself. Resigning active clears it here.
/// - A click sets `NotificationRouter.shared.pending` to (host, address). A's root view must observe it,
///   open `AgentRef(host:address:)` as a window (`openWindow(value:)`) and clear `pending`.
@MainActor
final class MacNotifications {
    static let shared = MacNotifications()

    private let delegate = NotificationDelegate()
    private var notifier: AgentNotifier?
    private var resigned: Task<Void, Never>?

    private init() {}

    /// Installs the click delegate and starts alerts from `sessions`. Safe to call more than once.
    func start(sessions: SessionStore) {
        guard notifier == nil else { return }
        UNUserNotificationCenter.current().delegate = delegate
        if Delivery.notifications { authorize() }
        let notifier = AgentNotifier(sessions: sessions)
        notifier.start()
        self.notifier = notifier
        // The app giving up focus: nothing on screen is seen any more, so every alert may fire.
        resigned = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didResignActiveNotification) {
                self?.focus(nil)
            }
        }
    }

    /// Asks the system for permission to alert. The system asks only once; later calls are no-ops.
    func authorize() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// The agent whose window is key while the app is active, or nil.
    func focus(_ ref: AgentRef?) {
        notifier?.focusedAddress = ref.map { (host: $0.host, address: $0.address) }
    }
}
