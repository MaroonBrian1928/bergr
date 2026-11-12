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
        let command: String
        if windows {
            // Through cmd, not a second powershell.exe: starting PowerShell to launch Python took
            // 1.5-2 s on a ThinkPad, cmd ~0.05 s. The line must survive cmd and PowerShell as the
            // SSH default shell alike: one double-quoted argument to `cmd /s /c` (no `$`, no inner
            // double quotes), and Python code without spaces, since cmd passes it unquoted. The
            // standard per-user runtime goes first on PATH (a fresh SSH session may still have the
            // pre-install PATH), then any python.exe on PATH.
            let compact = "J=__import__('json');B=__import__('base64');S=__import__('sys');"
                + "d=J.loads(B.b64decode(S.stdin.buffer.readline()));S.argv=d['argv'];"
                + "S.stdout.reconfigure(encoding='utf-8',newline=chr(10));S.stderr.reconfigure(encoding='utf-8');"
                + "exec(compile(d['script'],'agent-feed.py','exec'))"
            command = "cmd /d /s /c \"set PATH=%LOCALAPPDATA%\\Programs\\Python\\Python313;%PATH%&& python.exe -I -u -c \(compact)\""
        } else {
            command = "python3 -I -u -c \"\(code)\""
        }
        return Plan(command: command, input: Data((payload.base64EncodedString() + "\n").utf8))
    }
}
