import Foundation

/// Terminal emulators Bergr can open an attach in, in default-selection order.
public enum TerminalApp: String, CaseIterable, Sendable, Codable {
    case ghostty, iterm2, terminal, wezterm, kitty

    public var bundleID: String {
        switch self {
        case .ghostty: "com.mitchellh.ghostty"
        case .iterm2: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        case .wezterm: "com.github.wez.wezterm"
        case .kitty: "net.kovidgoyal.kitty"
        }
    }

    public var displayName: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iterm2: "iTerm2"
        case .terminal: "Terminal"
        case .wezterm: "WezTerm"
        case .kitty: "Kitty"
        }
    }

    /// How to start `script` (an executable `.command` file) in this terminal, whose app bundle is at `appPath`.
    public func launchPlan(appPath: String, script: String) -> LaunchPlan {
        switch self {
        case .ghostty:
            // Ghostty's CLI is not supported on macOS; `open -na` with `-e` runs the command in a new instance.
            LaunchPlan(executable: "/usr/bin/open", arguments: ["-na", appPath, "--args", "-e", script])
        case .iterm2, .terminal:
            LaunchPlan(executable: "/usr/bin/open", arguments: ["-a", appPath, script])
        case .wezterm:
            LaunchPlan(executable: appPath + "/Contents/MacOS/wezterm", arguments: ["start", "--", script])
        case .kitty:
            LaunchPlan(executable: appPath + "/Contents/MacOS/kitty", arguments: ["--single-instance", "--", script])
        }
    }
}

public struct LaunchPlan: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
}

/// The program that attaches to a herdr terminal, as argv (for local) or an ssh invocation (for a machine).
public enum AttachCommand {
    public struct Remote: Equatable, Sendable {
        public var user: String
        public var host: String
        public var port: Int
        public init(user: String, host: String, port: Int = 22) {
            self.user = user; self.host = host; self.port = port
        }
    }

    public enum Refusal: Error, Equatable { case address, user, host, port }

    /// `remote == nil` attaches on this Mac (through a login shell, so `~/.local/bin` is on PATH).
    public static func argv(remote: Remote?, address: String) throws -> [String] {
        guard matches(address, #"^[A-Za-z0-9._/][A-Za-z0-9._/-]*$"#) else { throw Refusal.address }
        guard let remote else {
            return ["/bin/zsh", "-lc", "exec hc attach \(quote(address))"]
        }
        guard matches(remote.user, #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#) else { throw Refusal.user }
        guard matches(remote.host, #"^[A-Za-z0-9][A-Za-z0-9.:_-]*$"#) else { throw Refusal.host }
        guard (1...65535).contains(remote.port) else { throw Refusal.port }
        var args = ["ssh", "-t"]
        if remote.port != 22 { args += ["-p", String(remote.port)] }
        args.append("\(remote.user)@\(remote.host)")
        args.append("PATH=\"$HOME/.local/bin:$PATH\" hc attach \(quote(address))")
        return args
    }

    /// The `.command` file's content: one `exec` of the quoted argv.
    public static func script(argv: [String]) -> String {
        "#!/bin/zsh -l\nexec " + argv.map(quote).joined(separator: " ") + "\n"
    }

    /// Single-quotes `s` for a POSIX shell.
    public static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil && !s.contains("\n")
    }
}
