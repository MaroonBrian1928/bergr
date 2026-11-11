import HerdrKit
import OSLog

/// Stub (chunk B): opens the user's terminal on `hc attach <address>` (locally) or
/// `ssh … hc attach <address>` (remote machine). `host` is nil for "this Mac".
@MainActor
enum TerminalLauncher {
    static func open(host: Host?, address: String) {
        Logger(subsystem: "bergr", category: "terminal-launcher")
            .info("open in terminal (stub): \(host?.name ?? "this Mac", privacy: .public) \(address, privacy: .public)")
    }
}
