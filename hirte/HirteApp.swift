import HerdrKit
import SwiftUI

@main
struct HirteApp: App {
    @State private var hosts = HostStore()
    @State private var keys = KeyLibrary()
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hosts)
                .environment(keys)
                // On the window, not with .preferredColorScheme: that leaves open sheets in the old
                // appearance and doesn't reliably go back to System.
                .onChange(of: appearance, initial: true) { _, appearance in appearance.apply() }
                #if DEBUG
                .task { ScreenRecording.startIfRequested() }
                #endif
        }
    }
}
