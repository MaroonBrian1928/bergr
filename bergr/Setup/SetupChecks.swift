import Foundation

/// The rows of a machine's Setup checklist.
enum SetupItem: String, CaseIterable, Identifiable, Sendable {
    case core, python, agents, push, statusLine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "herdr-core"
        case .python: "Python 3"
        case .agents: "Agent CLIs"
        case .push: "Push helper"
        case .statusLine: "Status line"
        }
    }
}

/// The agent CLIs Bergr starts on a machine.
enum AgentCLI: String, CaseIterable, Identifiable, Sendable {
    case claude, codex, antigravity
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// The command names it runs under, in the order to try (Antigravity's CLI is `agy`).
    var commands: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .antigravity: ["agy", "antigravity"]
        }
    }

    /// The install command to copy, where Bergr knows one.
    func installCommand(windows: Bool) -> String? {
        switch self {
        case .claude: windows ? "irm https://claude.ai/install.ps1 | iex" : "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "npm install -g @openai/codex"
        case .antigravity: nil
        }
    }
}

/// What one check found.
enum CheckState: Equatable, Sendable {
    case checking
    case ready(String)
    case missing(String)
    /// Installed, but older than the app's bundled version.
    case outdated(String)
    case failed(String)
}

/// The commands that check each item over SSH, and the parsers for what they print. Commands use
/// only what survives both a POSIX shell and cmd/PowerShell (see `ChatHelperLaunch`) on Windows.
enum SetupCheck {
    static func pythonCommand(windows: Bool) -> String {
        windows
            ? #"cmd /d /s /c "set PATH=%LOCALAPPDATA%\Programs\Python\Python313;%PATH%&& python.exe --version 2>&1""#
            : "python3 --version 2>&1"
    }

    /// "3.12.4" from `Python 3.12.4`; nil when Python 3 is missing or the answer is an error.
    static func parsePython(_ output: String) -> String? {
        guard let match = output.firstMatch(of: /Python (3\.\d+(?:\.\d+)?)/) else { return nil }
        return String(match.1)
    }

    static func agentCommand(_ agent: AgentCLI, windows: Bool) -> String {
        if windows {
            let tries = agent.commands.map { "(where \($0) >nul 2>&1 && (echo found & \($0) --version 2>nul))" }
            return #"cmd /d /s /c "\#(tries.joined(separator: " || "))""#
        }
        let names = agent.commands.joined(separator: " ")
        return "export PATH=\"$HOME/.local/bin:$PATH\"; for c in \(names); do "
            + "if command -v \"$c\" >/dev/null 2>&1; then echo found; \"$c\" --version </dev/null 2>/dev/null | head -n 1; break; fi; done"
    }

    /// Whether the agent is on the machine, and its version line when it printed one.
    static func parseAgent(_ output: String) -> (installed: Bool, version: String?) {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let marker = lines.firstIndex(of: "found") else { return (false, nil) }
        let version = lines.dropFirst(marker + 1).first { !$0.isEmpty }
        return (true, version)
    }

    static func statusLineCommand(windows: Bool) -> String {
        windows
            ? #"cmd /d /s /c "findstr /c:statusline-herdr %USERPROFILE%\.claude\settings.json >nul 2>&1 && echo set || echo missing""#
            : "if grep -qs statusline-herdr \"$HOME/.claude/settings.json\"; then echo set; else echo missing; fi"
    }

    /// True when Claude Code's settings.json names Bergr's status line.
    static func parseStatusLine(_ output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == "set" }
    }

    /// The helper's status from install-helper.py: its last line is one JSON object.
    static func parseHelper(_ output: String) -> (installed: Bool, version: Int?)? {
        guard let line = output.split(whereSeparator: \.isNewline).last,
              let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        return (object["installed"] as? Bool ?? false, object["version"] as? Int)
    }
}
