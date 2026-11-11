import Foundation
import HerdrKit

/// Gets a machine this one's herdr-core links to ready to add directly, through that link: who
/// you are there, an address the phone can reach, and this phone's key allowed in.
enum LinkedSetup {
    struct Found: Equatable {
        var user: String?
        var address: String?
        var keyAdded: Bool
    }

    /// Prints the user, then the first LAN address, then "key-ok" once the key (argument 1) is in
    /// authorized_keys (added only when missing).
    static let script = """
        id -un
        (hostname -I 2>/dev/null || ipconfig getifaddr en0 2>/dev/null) | cut -d' ' -f1
        mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys \
          && { grep -qxF "$1" ~/.ssh/authorized_keys || printf '%s\\n' "$1" >> ~/.ssh/authorized_keys; } && echo key-ok
        """

    static func parse(_ stdout: String) -> Found {
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        func at(_ i: Int) -> String? { i < lines.count && !lines[i].isEmpty ? lines[i] : nil }
        return Found(user: at(0), address: at(1), keyAdded: lines.contains("key-ok"))
    }

    /// The core's own target when the phone can use it (an IP or a name with a dot); an SSH
    /// config alias (`newcloud`) only works on that computer, so the machine's address instead.
    static func address(target: String?, found: String?) -> String? {
        if let target, target.contains(".") || target.contains(":") { return target }
        return found ?? target
    }

    /// Runs it on the machine; nil when it can't (no `sh` there, e.g. Windows).
    @MainActor
    static func run(on machine: String, keyLine: String?, session: HostSession) async -> Found? {
        guard let out = try? await session.exec(["sh", "-c", script, "sh", keyLine ?? ""], on: machine, timeout: 15),
              out.code == 0 || !out.stdout.isEmpty else { return nil }
        var found = parse(out.stdout)
        if keyLine == nil { found.keyAdded = false }
        return found
    }
}
