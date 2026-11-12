import Foundation

/// Keep exec requests short. Windows SSH cannot launch an 85 KB command line; JSON over
/// stdin also keeps paths, session IDs and the Python source out of shell parsing entirely.
enum ChatHelperLaunch {
    struct Plan: Sendable {
        let command: String
        let input: Data
    }

    static func make(script: String, agent: String, pid: Int32, cwd: String,
                     sessionHint: String?, windows: Bool) throws -> Plan {
        let payload = try JSONSerialization.data(withJSONObject: [
            "script": script,
            "argv": ["agent-feed.py", agent, String(pid), cwd, sessionHint ?? "-"],
        ])
        let code = "import base64,json,sys;d=json.loads(base64.b64decode(sys.stdin.buffer.readline()));"
            + "sys.argv=d['argv'];sys.stdout.reconfigure(encoding='utf-8',newline=chr(10));"
            + "sys.stderr.reconfigure(encoding='utf-8');exec(compile(d['script'],'agent-feed.py','exec'))"
        let args = "-I -u -c \"\(code)\""
        let command: String
        if windows {
            // A fresh SSH session may still have the pre-install PATH. Prefer the standard
            // per-user runtime when present, then an existing python.exe on PATH.
            let bootstrap = "$ErrorActionPreference='Stop';"
                + "$p=Join-Path $env:LOCALAPPDATA 'Programs\\Python\\Python313\\python.exe';"
                + "if (!(Test-Path -LiteralPath $p)) {$p='python.exe'};"
                + "& $p -I -u -c \"\(code)\";exit $LASTEXITCODE"
            // EncodedCommand avoids a second round of parsing by either cmd or PowerShell
            // as the SSH default shell. The helper's output is JSON text, not binary frames.
            command = "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "
                + Data(bootstrap.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }).base64EncodedString()
        } else {
            command = "python3 \(args)"
        }
        return Plan(command: command, input: Data((payload.base64EncodedString() + "\n").utf8))
    }
}
