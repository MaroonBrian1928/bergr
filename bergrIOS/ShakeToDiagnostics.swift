import SwiftUI
import UIKit

/// Shake the phone to open Diagnostics (Settings → About → Diagnostics), for when something just
/// went wrong. Off in Settings with "Shake for Diagnostics". Not while typing: there iOS's own
/// shake means Undo Typing.
enum ShakeToDiagnostics {
    static let enabledKey = "bergr.shakeForDiagnostics"
    static let shook = Notification.Name("bergr.deviceShook")

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        guard motion == .motionShake, ShakeToDiagnostics.enabled else { return }
        // Typing: the shake is the system's Undo.
        if let responder = firstResponderView, responder is UITextInput { return }
        NotificationCenter.default.post(name: ShakeToDiagnostics.shook, object: nil)
    }

    private var firstResponderView: UIView? {
        func find(_ view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(self)
    }
}

/// Shows Diagnostics in a sheet when the phone is shaken.
struct ShakeToDiagnosticsModifier: ViewModifier {
    @State private var open = false

    func body(content: Content) -> some View {
        content
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
