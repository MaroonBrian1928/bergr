import AppKit
import HerdrKit
import OSLog
import SwiftUI

/// Opens the user's terminal on `hc attach <address>` (locally) or `ssh … hc attach <address>` (remote machine).
/// `host` is nil for "this Mac". The attach runs from a generated `.command` script.
@MainActor
enum TerminalLauncher {
    static let preferenceKey = "bergr.terminalApp"
    private static let log = Logger(subsystem: "bergr", category: "terminal-launcher")

    static func appURL(_ app: TerminalApp) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
    }

    static var installed: [TerminalApp] { TerminalApp.allCases.filter { appURL($0) != nil } }

    /// The saved choice if still installed, else the first installed one (Terminal is always there).
    static var selected: TerminalApp {
        let saved = UserDefaults.standard.string(forKey: preferenceKey).flatMap(TerminalApp.init(rawValue:))
        if let saved, appURL(saved) != nil { return saved }
        return installed.first ?? .terminal
    }

    /// Returns an error message if the launch failed, else nil.
    @discardableResult
    static func open(host: Host?, address: String) -> String? {
        let app = selected
        do {
            guard let appURL = appURL(app) else { throw Failure("\(app.displayName) is not installed.") }
            let remote = host.map { AttachCommand.Remote(user: $0.target.username, host: $0.target.host, port: $0.target.port) }
            let argv = try AttachCommand.argv(remote: remote, address: address)
            let script = try writeScript(AttachCommand.script(argv: argv))
            let plan = app.launchPlan(appPath: appURL.path, script: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            try process.run()
            return nil
        } catch is AttachCommand.Refusal {
            log.error("refused an unsafe address, user, host or port")
            return "Bergr will not open this in a terminal (unsupported characters in the address or machine)."
        } catch {
            log.error("launch failed: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private static func writeScript(_ content: String) throws -> URL {
        let fm = FileManager.default
        let caches = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "bergr").appendingPathComponent("attach")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        let url = dir.appendingPathComponent(UUID().uuidString + ".command")
        try content.write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}

/// Settings section: which terminal "Open in terminal" uses.
struct TerminalSettingsView: View {
    @AppStorage(TerminalLauncher.preferenceKey) private var choice = ""

    var body: some View {
        let installed = TerminalLauncher.installed
        Section {
            Picker("Terminal", selection: Binding(
                get: { installed.contains(where: { $0.rawValue == choice }) ? choice : TerminalLauncher.selected.rawValue },
                set: { choice = $0 }
            )) {
                ForEach(installed, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
            }
        } header: {
            Text("Open in terminal")
        } footer: {
            Text("Opens the terminal attached to an agent. For a remote machine this runs the system ssh, which cannot use Bergr's keys: ssh to that machine must already work from your terminal.")
        }
    }
}
