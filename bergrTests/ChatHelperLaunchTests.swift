import Foundation
import Testing
@testable import bergr

struct ChatHelperLaunchTests {
    private func payload(_ plan: ChatHelperLaunch.Plan) throws -> [String: Any] {
        let line = String(decoding: plan.input, as: UTF8.self)
        let start = try #require(line.range(of: "b64decode('")).upperBound
        let end = try #require(line[start...].firstIndex(of: "'"))
        let data = try #require(Data(base64Encoded: String(line[start..<end])))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func windowsCommandIsATinyStageOne() throws {
        let script = String(repeating: "# python source\n", count: 10000)
        let cwd = #"C:\work\spaces & quotes' and 日本語"#
        let plan = try ChatHelperLaunch.make(script: script, agent: "claude", pid: 123,
            cwd: cwd, sessionHint: "abc", windows: true, stage2: "pass")
        #expect(plan.command.utf8.count < 512)
        #expect(plan.command.hasPrefix(#"cmd /d /s /c "set PATH="#))
        // One quoted argument for cmd, safe under PowerShell as the default shell too.
        #expect(plan.command.filter { $0 == "\"" }.count == 2)
        #expect(!plan.command.contains("$"))
        let python = try #require(plan.command.range(of: " -c ")).upperBound
        #expect(!plan.command[python...].dropLast().contains(" "))
        #expect(!plan.command.contains(cwd))
        #expect(plan.command.contains("stdin.buffer.readline"))
        let decoded = try payload(plan)
        #expect(decoded["sha"] as? String == ChatHelperLaunch.sha256(script))
        #expect(decoded["argv"] as? [String] == ["agent-feed.py", "claude", "123", cwd, "abc", "0", "-", "0"])
        // The source travels only on request, as one base64 line.
        let source = String(decoding: plan.sourceLine, as: UTF8.self).trimmingCharacters(in: .newlines)
        #expect(Data(base64Encoded: source) == Data(script.utf8))
    }

    @Test func unixAlsoUsesAShortUnbufferedCommand() throws {
        let plan = try ChatHelperLaunch.make(script: "print('hello')", agent: "codex", pid: 0,
            cwd: "/work/a'b", sessionHint: nil, windows: false, stage2: "pass")
        #expect(plan.command.hasPrefix("python3 -I -u -c "))
        #expect(!plan.command.contains("print('hello')"))
        #expect(plan.input.last == 10)
        #expect(plan.sourceLine.last == 10)
    }

    @Test func expensiveFlagAndCursorGoInArgv() throws {
        let plan = try ChatHelperLaunch.make(script: "x", agent: "claude", pid: 1, cwd: "/w", sessionHint: nil,
            windows: false, expensive: true, cursor: .init(session: "s.jsonl", offset: 42), stage2: "pass")
        #expect(try payload(plan)["argv"] as? [String] == ["agent-feed.py", "claude", "1", "/w", "-", "1", "s.jsonl", "42"])
    }

    @Test func bundledStageTwoIsPresent() {
        #expect(ChatHelperLaunch.stage2Source?.contains("need-source") == true)
    }
}
