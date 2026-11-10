// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import HerdrKit
import SwiftUI
import UserNotifications

@main
struct BergrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var hosts = HostStore()
    @State private var keys = KeyLibrary()
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    private let notificationDelegate = NotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hosts)
                .environment(keys)
                // On the window, not with .preferredColorScheme: that leaves open sheets in the old
                // appearance and doesn't reliably go back to System.
                .onChange(of: appearance, initial: true) { _, appearance in appearance.apply() }
                // Live Activity rows: bergr://terminal?host=<uuid>&address=<t7>
                .onOpenURL { url in
                    if let target = LiveActivityController.target(of: url) {
                        NotificationRouter.shared.pending = target
                    }
                }
                #if DEBUG
                .task { ScreenRecording.startIfRequested() }
                #endif
        }
    }
}
