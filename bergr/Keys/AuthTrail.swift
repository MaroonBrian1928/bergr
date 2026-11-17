import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The last Face ID / key-unlock events, kept on the device so a failed unlock can be looked at
/// afterwards (Settings → About → Face ID Log). Times, app state and outcomes only: no key data.
@MainActor
enum AuthTrail {
    static let key = "bergr.authTrail"
    static let kept = 40

    static func note(_ event: String) {
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        let time = Date.now.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(1)))
        lines.append("\(time)  \(event)  [\(appState)]")
        UserDefaults.standard.set(Array(lines.suffix(kept)), forKey: key)
    }

    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    private static var appState: String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "?"
        }
        #else
        "mac"
        #endif
    }
}

struct AuthTrailView: View {
    @State private var lines = AuthTrail.lines

    var body: some View {
        List {
            if lines.isEmpty {
                Text("Nothing yet. Events appear here when a key is unlocked.").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.footnote.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("Face ID Log")
        .toolbar {
            ToolbarItem {
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(lines.joined(separator: "\n")) }
            }
        }
        .refreshable { lines = AuthTrail.lines }
    }
}
