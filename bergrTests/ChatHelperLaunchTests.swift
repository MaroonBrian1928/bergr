import Foundation
import Testing
@testable import bergr

struct ChatHelperLaunchTests {
    @Test func windowsSourceAndArgumentsTravelOverStdin() throws {
        let script = String(repeating: "# python source\n", count: 10000)
        let cwd = #"C:\work\spaces & quotes' and 日本語"#
        let plan = try ChatHelperLaunch.make(script: script, agent: "claude", pid: 123,
            cwd: cwd, sessionHint: "abc", windows: true)
        #expect(plan.command.utf8.count < 2048)
        #expect(plan.command.hasPrefix("powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand "))
        #expect(!plan.command.contains(cwd))
        let data = try #require(Data(base64Encoded: String(decoding: plan.input, as: UTF8.self).trimmingCharacters(in: .newlines)))
        let decoded = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(decoded["script"] as? String == script)
        #expect(decoded["argv"] as? [String] == ["agent-feed.py", "claude", "123", cwd, "abc"])
    }

    @Test func unixAlsoUsesAShortUnbufferedCommand() throws {
        let plan = try ChatHelperLaunch.make(script: "print('hello')", agent: "codex", pid: 0,
            cwd: "/work/a'b", sessionHint: nil, windows: false)
        #expect(plan.command.hasPrefix("python3 -I -u -c "))
        #expect(!plan.command.contains("print('hello')"))
        #expect(plan.input.last == 10)
    }
}
