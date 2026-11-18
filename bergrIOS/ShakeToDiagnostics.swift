import SwiftUI
import UIKit

/// Shake the phone to open Diagnostics (Settings → About → Diagnostics), for when something just
/// went wrong. Off in Settings with "Shake for Diagnostics", which also gives the shake back to
/// iOS's Undo Typing.
enum ShakeToDiagnostics {
    static let enabledKey = "bergr.shakeForDiagnostics"
    static let shook = Notification.Name("bergr.deviceShook")

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake, ShakeToDiagnostics.enabled else { return }
        NotificationCenter.default.post(name: ShakeToDiagnostics.shook, object: nil)
    }
}

/// Shows Diagnostics in a sheet when the phone is shaken.
struct ShakeToDiagnosticsModifier: ViewModifier {
    @State private var open = false

    func body(content: Content) -> some View {
        content
            // A chat's keyboard is nearly always up, so the shake is ours: iOS's own shake-to-undo
            // is off while this is on (undo stays on three fingers and the keyboard).
            .onAppear { UIApplication.shared.applicationSupportsShakeToEdit = !ShakeToDiagnostics.enabled }
            .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                UIApplication.shared.applicationSupportsShakeToEdit = !ShakeToDiagnostics.enabled
            }
            .onReceive(NotificationCenter.default.publisher(for: ShakeToDiagnostics.shook)) { _ in open = true }
            .sheet(isPresented: $open) {
                NavigationStack {
                    AuthTrailView(shakeToggle: true)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { open = false }
                            }
                        }
                }
                .sensoryFeedback(.impact(weight: .light), trigger: open)
            }
    }
}
