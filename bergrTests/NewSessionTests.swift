import Foundation
import HerdrKit
import Testing
@testable import bergr

struct NewSessionTests {
    func terminal(_ address: String, cwd: String, ms: UInt64, agent: Bool = true) throws -> Terminal {
        let status = agent ? #","status":{"state":"idle","app":"claude-code"}"# : ""
        let json = """
        {"address":"\(address)","name":"\(address)","state":"live","turn":1,"labels":{},"cwd":"\(cwd)",
         "created_ms":\(ms),"status_ms":\(ms)\(status)}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func parsesTheAgentsFoundInAFixedOrder() {
        let output = "codex\t/opt/homebrew/bin/codex\nclaude\t/Users/me/.local/bin/claude\n"
        let found = NewSession.parseLocated(output)
        #expect(found.map(\.agent) == [.claude, .codex])
        #expect(found.first?.path == "/Users/me/.local/bin/claude")
        // Shell noise from a login profile, and relative or unknown names, are ignored.
        #expect(NewSession.parseLocated("Welcome!\nagy\tagy\nvim\t/usr/bin/vim\n").isEmpty)
    }

    @Test func recentFoldersAreAgentFoldersNewestFirstWithoutRepeats() throws {
        let folders = NewSession.recentFolders([
            try terminal("t1", cwd: "/Users/me/src/old", ms: 1),
            try terminal("t2", cwd: "/Users/me/src/app", ms: 3),
            try terminal("t3", cwd: "/Users/me/src/app", ms: 2),
            try terminal("t4", cwd: "/Users/me/shell", ms: 9, agent: false),
            try terminal("laptop/t5", cwd: "/Users/me/elsewhere", ms: 8),
        ])
        #expect(folders == ["/Users/me/src/app", "/Users/me/src/old"])
    }

    @Test func showsHomeAsTilde() {
        #expect(NewSession.display("/Users/me/src/app", home: "/Users/me") == "~/src/app")
        #expect(NewSession.display("/Users/meg/x", home: "/Users/me") == "/Users/meg/x")
        #expect(NewSession.display("/srv/x", home: nil) == "/srv/x")
    }

    @Test func firstMessageBecomesThePrompt() {
        #expect(NewSession.argv(path: "/bin/claude", message: "  ") == ["/bin/claude"])
        #expect(NewSession.argv(path: "/bin/claude", message: " Fix the build \n") == ["/bin/claude", "Fix the build"])
    }
}
