import AppKit
import SwiftUI

/// Read ownership follows the actual key window, including app activation and Settings windows.
struct KeyWindowObserver: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) { view.changed = changed }

    static func dismantleNSView(_ view: WindowView, coordinator: ()) {
        view.stop()
    }

    final class WindowView: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        private func report() { changed(window?.isKeyWindow == true && NSApp.isActive) }

        func stop() {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
            tokens = []
            changed(false)
        }
    }
}
