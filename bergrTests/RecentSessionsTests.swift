import Foundation
import Testing
@testable import bergr

struct RecentSessionsTests {
    @Test func decodesTheHelpersLine() {
        let output = "banner\n[{\"id\":\"abc\",\"title\":\"Fix it\",\"mtime\":1700000000.5,\"count\":7}]\n"
        let list = RecentSessions.decode(output)
        #expect(list.count == 1)
        #expect(list[0].id == "abc")
        #expect(list[0].title == "Fix it")
        #expect(list[0].count == 7)
        #expect(list[0].date == Date(timeIntervalSince1970: 1_700_000_000.5))
        #expect(RecentSessions.decode("garbage").isEmpty)
    }

    @Test func resumeCommandPerAgent() {
        #expect(RecentSessions.resumeArgv(agent: .claude, path: "/bin/claude", id: "a1-b2")
                == ["/bin/claude", "--resume", "a1-b2"])
        #expect(RecentSessions.resumeArgv(agent: .codex, path: "/bin/codex", id: "019a-xyz")
                == ["/bin/codex", "resume", "019a-xyz"])
        #expect(RecentSessions.resumeArgv(agent: .antigravity, path: "/bin/agy", id: "x") == nil)
    }

    @Test func refusesIdsThatCouldInjectCommands() {
        #expect(RecentSessions.resumeArgv(agent: .claude, path: "/c", id: "a; rm -rf ~") == nil)
        #expect(RecentSessions.resumeArgv(agent: .codex, path: "/c", id: "") == nil)
    }

    @Test func quotesTheShellLine() {
        #expect(RecentSessions.shellLine(["/opt/my tools/claude", "--resume", "it's"])
                == "'/opt/my tools/claude' --resume 'it'\\''s'")
        #expect(RecentSessions.shellLine(["/bin/codex", "resume", "a-1"]) == "/bin/codex resume a-1")
    }

    @Test func launchKeepsTheCommandShortAndPlain() throws {
        let plan = try RecentSessions.launch(script: "print(1)", agent: .claude, folder: "C:\\Users\\me\\it's", windows: true)
        #expect(plan.command.hasPrefix("cmd /d /s /c"))
        #expect(!plan.command.contains("$"))
        #expect(!plan.command.contains("it's"))
        let unix = try RecentSessions.launch(script: "print(1)", agent: .codex, folder: "/a b", windows: false)
        #expect(unix.command.hasPrefix("python3 -I"))
        #expect(String(decoding: unix.input, as: UTF8.self).hasSuffix("\n"))
    }
}
