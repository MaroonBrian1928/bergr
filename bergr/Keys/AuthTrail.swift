import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The last Face ID / key-unlock events, kept on the device so a failed unlock can be looked at
/// afterwards (Settings → About → Diagnostics), with other app events such as a chat that kept bouncing. Times, app state and outcomes only: no key data.
@MainActor
enum AuthTrail {
    static let key = "bergr.authTrail"
    static let kept = 200

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
    @State private var report = ProblemReportForm()
    /// Opened by shaking the phone: the switch for that is at the top, so it can be turned off here.
    var shakeToggle = false
    @AppStorage("bergr.shakeForDiagnostics") private var shakeForDiagnostics = true

    var body: some View {
        List {
            if shakeToggle {
                Section {
                    Toggle("Shake for Diagnostics", isOn: $shakeForDiagnostics)
                } footer: {
                    Text("Also in Settings → About.")
                }
            }
            ProblemReportSection(form: report, lines: lines)
            if lines.isEmpty {
                Text("Nothing yet. Face ID unlocks and app problems appear here.").foregroundStyle(.secondary)
            }
            ForEach(Array(lines.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.footnote.monospaced()).textSelection(.enabled)
            }
        }
        .problemReportPresentation(report, lines: lines)
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem {
                Button("Copy", systemImage: "doc.on.doc") { Pasteboard.copy(lines.joined(separator: "\n")) }
            }
        }
        .refreshable { lines = AuthTrail.lines }
    }
}
