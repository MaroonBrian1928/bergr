import CryptoKit
import Foundation

/// Keep exec requests short. Windows SSH cannot launch an 85 KB command line, and the helper is
/// 70 KB: the command carries a tiny stage 1 that execs the first line of stdin (stage 2). Stage 2
/// runs the helper cached on the machine by its SHA-256, and only asks for the source
/// (`{"t":"need-source"}`, answered with `Plan.sourceLine`) when the cache has none. Paths, session
/// IDs and the source never pass through shell parsing.
enum ChatHelperLaunch {
    struct Plan: Sendable {
        let command: String
        /// Stage 2: the first line on stdin.
        let input: Data
        /// The helper's source as one base64 line, for `need-source`.
        let sourceLine: Data
    }

    /// Where reading stood in a conversation file (the helper's `cursor` event).
    struct Cursor: Equatable, Sendable {
        let session: String
        let offset: Int
    }

    static let stage2Source: String? = Bundle.main.url(forResource: "agent-stage2", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    static func sha256(_ script: String) -> String {
        SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func make(script: String, agent: String, pid: Int32, cwd: String,
                     sessionHint: String?, windows: Bool, expensive: Bool = false,
                     cursor: Cursor? = nil, stage2: String? = nil) throws -> Plan {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sha": sha256(script),
            "argv": ["agent-feed.py", agent, String(pid), cwd, sessionHint ?? "-", expensive ? "1" : "0",
                     cursor?.session ?? "-", String(cursor?.offset ?? 0)],
        ])
        let code = Data((stage2 ?? stage2Source ?? "").utf8)
        let line = "import base64,json;D=json.loads(base64.b64decode('\(payload.base64EncodedString())'));"
            + "exec(base64.b64decode('\(code.base64EncodedString())'))"
        // Stage 1: no spaces, no `$`, no double quotes, so it survives cmd and PowerShell alike.
        let stage1 = "S=__import__('sys');exec(S.stdin.buffer.readline())"
        let command: String
        if windows {
            // Through cmd, not a second powershell.exe: starting PowerShell to launch Python took
            // 1.5-2 s on a ThinkPad, cmd ~0.05 s. The line must survive cmd and PowerShell as the
            // SSH default shell alike: one double-quoted argument to `cmd /s /c` (no `$`, no inner
            // double quotes), and Python code without spaces, since cmd passes it unquoted. The
            // standard per-user runtime goes first on PATH (a fresh SSH session may still have the
            // pre-install PATH), then any python.exe on PATH.
            command = "cmd /d /s /c \"set PATH=%LOCALAPPDATA%\\Programs\\Python\\Python313;%PATH%&& python.exe -I -u -c \(stage1)\""
        } else {
            command = "python3 -I -u -c \"\(stage1)\""
        }
        return Plan(command: command, input: Data((line + "\n").utf8),
                    sourceLine: Data((Data(script.utf8).base64EncodedString() + "\n").utf8))
    }
}
