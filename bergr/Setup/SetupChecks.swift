import Foundation

/// The rows of a machine's Setup checklist.
enum SetupItem: String, CaseIterable, Identifiable, Sendable {
    case core, git, python, sleep, agents, push, alerts, statusLine
    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: "herdr-core"
        case .git: "Git"
        case .sleep: "Sleep"
        case .python: "Python 3"
        case .agents: "Agent CLIs"
        case .push: "Push helper"
        case .alerts: "Alerts reaching your phone"
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
    /// Works, but something will bite later (the machine sleeps, an agent isn't signed in).
    case warning(String)
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
        return "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; for c in \(names); do "
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

extension SetupCheck {
    // MARK: Core version

    /// The oldest herdr-core Bergr works with. HerdrKit still carries workarounds for 0.1.16 (see the
    /// comments in Models.swift), so nothing older is known to work.
    static let minimumCoreVersion = "0.1.16"

    /// Dotted numeric parts of a version ("v0.1.20-beta" -> [0, 1, 20]); nil when there are none.
    static func versionParts(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespaces).drop { $0 == "v" || $0 == "V" }
            .split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// True when `version` is older than `minimum`; false when either can't be read.
    static func isOlder(_ version: String, than minimum: String) -> Bool {
        guard var a = versionParts(version), var b = versionParts(minimum) else { return false }
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return a.lexicographicallyPrecedes(b)
    }

    static func coreState(version: String?) -> CheckState {
        guard let version else { return .ready("running") }
        if isOlder(version, than: minimumCoreVersion) {
            return .outdated("version \(version), Bergr needs \(minimumCoreVersion) or newer. Update herdr-core on the machine.")
        }
        return .ready("version \(version)")
    }

    // MARK: Git

    /// Prints the OS name, then git's version. On a Mac without developer tools `/usr/bin/git` is a
    /// stub that pops up an installer on the machine, so don't run it then.
    static func gitCommand(windows: Bool) -> String {
        if windows { return #"cmd /d /s /c "git --version 2>&1""# }
        return "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; uname -s; "
            + "if [ \"$(uname -s)\" = Darwin ] && ! xcode-select -p >/dev/null 2>&1 && [ \"$(command -v git)\" = /usr/bin/git ]; then "
            + "echo missing; else git --version </dev/null 2>&1; fi"
    }

    /// "2.39.3" from `git version 2.39.3 (Apple Git-145)`; nil when git is missing.
    static func parseGit(_ output: String) -> String? {
        output.firstMatch(of: /git version (\d+(?:\.\d+)*)/).map { String($0.1) }
    }

    enum HostOS: Equatable, Sendable { case mac, linux, windows }

    /// The OS from the first line of a POSIX probe that begins with `uname -s`.
    static func parseOS(_ output: String) -> HostOS? {
        switch output.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces) {
        case "Darwin": .mac
        case "Linux": .linux
        default: nil
        }
    }

    // MARK: Sleep

    static func sleepCommand() -> String {
        "if [ \"$(uname -s)\" = Darwin ]; then echo darwin; pmset -g custom 2>&1; "
            + "else echo linux; systemctl is-enabled sleep.target suspend.target 2>&1; fi"
    }

    enum SleepFinding: Equatable, Sendable {
        case staysAwake
        case sleeps(minutes: Int?)
        case unknown
    }

    /// Reads `sleepCommand`'s output: on a Mac, `sleep` minutes in the "AC Power" section of
    /// `pmset -g custom` (0 means never); on Linux, whether `sleep.target` or `suspend.target` is masked.
    static func parseSleep(_ output: String) -> SleepFinding {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first else { return .unknown }
        let rest = lines.dropFirst()
        if first == "darwin" {
            var inAC = false
            for line in rest {
                if line.hasSuffix(":") { inAC = line == "AC Power:"; continue }
                guard inAC else { continue }
                let fields = line.split(whereSeparator: \.isWhitespace)
                if fields.count >= 2, fields[0] == "sleep", let minutes = Int(fields[1]) {
                    return minutes == 0 ? .staysAwake : .sleeps(minutes: minutes)
                }
            }
            return .unknown
        }
        if first == "linux" {
            let known: Set<String> = ["masked", "masked-runtime", "static", "enabled", "disabled", "indirect",
                                      "generated", "linked", "linked-runtime", "alias", "transient"]
            let statuses = rest.filter { known.contains($0) }
            guard !statuses.isEmpty else { return .unknown }
            return statuses.contains { $0.hasPrefix("masked") } ? .staysAwake : .sleeps(minutes: nil)
        }
        return .unknown
    }

    /// First helper version that holds the machine awake while agents work.
    static let keepAwakeHelperVersion = 17

    static func sleepState(_ finding: SleepFinding, keepAwake: Bool = false, helperVersion: Int? = nil) -> CheckState {
        if case .sleeps = finding, keepAwake, let helperVersion, helperVersion >= keepAwakeHelperVersion {
            return .ready("Kept awake by Bergr while agents work")
        }
        switch finding {
        case .staysAwake: return .ready("Stays awake on power")
        case .unknown: return .ready("Couldn't tell. Check the machine's power settings.")
        case .sleeps(let minutes):
            return .warning(minutes.map { "Sleeps after \($0) min on power, and Bergr can't reach it then." }
                            ?? "Can suspend, and Bergr can't reach it then.")
        }
    }

    // MARK: Signed in

    /// A cheap, non-interactive, offline probe of whether the agent is signed in; nil where Bergr
    /// knows no reliable one (Antigravity), so it's skipped rather than guessed.
    static func signInCommand(_ agent: AgentCLI, windows: Bool) -> String? {
        let probe: String
        switch agent {
        case .claude: probe = windows ? "claude auth status 2>nul" : "claude auth status </dev/null 2>/dev/null"
        case .codex: probe = windows ? "codex login status 2>&1" : "codex login status </dev/null 2>&1"
        case .antigravity: return nil
        }
        if windows { return #"cmd /d /s /c "\#(probe)""# }
        return "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; \(probe)"
    }

    /// Whether the probe says signed in; nil when the output is neither (an older CLI without the
    /// subcommand, an error).
    static func parseSignedIn(_ agent: AgentCLI, output: String) -> Bool? {
        switch agent {
        case .claude:
            guard let match = output.firstMatch(of: /"loggedIn"\s*:\s*(true|false)/) else { return nil }
            return match.1 == "true"
        case .codex:
            let text = output.lowercased()
            if text.contains("not logged in") { return false }
            if text.contains("logged in") { return true }
            return nil
        case .antigravity:
            return nil
        }
    }

    /// The command to sign in; it opens a browser or asks for a code, so it needs a terminal.
    static func signInHint(_ agent: AgentCLI) -> String? {
        switch agent {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .antigravity: nil
        }
    }

    // MARK: Fixes

    static func gitFix(os: HostOS?) -> SetupFix? {
        switch os {
        case .mac: SetupFix(command: "xcode-select --install", runnable: false)
        case .linux: SetupFix(command: "sudo apt-get install -y git || sudo dnf install -y git || sudo pacman -S git", runnable: false)
        case .windows: SetupFix(command: "winget install --id Git.Git -e", runnable: false)
        case nil: nil
        }
    }

    static func sleepFix(os: HostOS?) -> SetupFix? {
        switch os {
        case .mac: SetupFix(command: "sudo pmset -c sleep 0", runnable: false)
        case .linux: SetupFix(command: "sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target", runnable: false)
        default: nil
        }
    }

    /// Claude Code's script needs no sudo; Codex's npm install can, so a failure there leaves Copy.
    static func installFix(_ agent: AgentCLI, windows: Bool) -> SetupFix? {
        agent.installCommand(windows: windows).map { SetupFix(command: $0, runnable: !windows) }
    }
}

/// A fix for a check, and whether Bergr may run it for you.
struct SetupFix: Equatable, Sendable {
    let command: String
    /// True for a command that needs no sudo and no prompts, so the Run button can send it.
    let runnable: Bool
}

/// Runs a fix on the machine, then checks again: the state machine behind a row's Run button.
@MainActor @Observable
final class SetupRepair {
    enum State: Equatable {
        case running
        /// Ran, but the check still isn't satisfied; why, and the last lines of output.
        case failed(String)
    }

    private(set) var states: [String: State] = [:]

    nonisolated static let marker = "__bergr_exit="

    /// Wraps a fix so its output includes stderr and its exit status on a last line.
    nonisolated static func wrap(_ command: String) -> String {
        "{ export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; \(command); } 2>&1; echo \(marker)$?"
    }

    /// The exit status and the last few lines of what the command printed.
    nonisolated static func parse(_ output: String, tailLines: Int = 6) -> (exit: Int?, tail: String) {
        var lines = output.replacingOccurrences(of: "\r", with: "\n")
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var exit: Int?
        if let last = lines.last, last.hasPrefix(marker) {
            exit = Int(last.dropFirst(marker.count))
            lines.removeLast()
        }
        let tail = lines.suffix(tailLines).map { String($0.prefix(200)) }.joined(separator: "\n")
        return (exit, tail)
    }

    /// Runs `fix` with `execute`, then `recheck`s. Returns true when the recheck is satisfied. A
    /// second call for the same id while one runs does nothing.
    @discardableResult
    func run(_ id: String, fix: SetupFix, execute: (String) async throws -> String,
             recheck: () async -> Bool) async -> Bool {
        guard states[id] != .running else { return false }
        states[id] = .running
        var tail = ""
        var failure: String?
        do {
            let parsed = Self.parse(try await execute(Self.wrap(fix.command)))
            tail = parsed.tail
            if let code = parsed.exit, code != 0 { failure = "Exited with status \(code)." }
        } catch {
            failure = error.localizedDescription
        }
        if await recheck() {
            states[id] = nil
            return true
        }
        let detail = [failure ?? "It ran, but the check still fails.", tail].filter { !$0.isEmpty }.joined(separator: "\n")
        states[id] = .failed(detail)
        return false
    }
}
