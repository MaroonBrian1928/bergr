import Foundation
import HerdrKit
import Testing
@testable import bergr

struct AgentsViewTests {
    private func terminal(_ address: String, state: String? = nil, app: String? = nil, fg: String = "zsh",
                          statusMs: Int? = nil) throws -> Terminal {
        let appPart = app.map { ",\"app\":\"\($0)\"" } ?? ""
        let status = state.map { "\"status\":{\"state\":\"\($0)\"\(appPart)}," } ?? ""
        let ms = statusMs.map { "\"status_ms\":\($0)," } ?? ""
        let json = """
        {"address":"\(address)","state":"live",\(status)\(ms)"foreground":{"pid":1,"name":"\(fg)","argv":["\(fg)"],"cwd":"/x"}}
        """
        return try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    }

    @Test func kinds() throws {
        #expect(AgentKind.of(try terminal("a", state: "working", app: "claude-code", fg: "claude")) == .claude)
        #expect(AgentKind.of(try terminal("b", state: "idle", app: "codex", fg: "codex")) == .codex)
        #expect(AgentKind.of(try terminal("c", state: "idle", app: "antigravity", fg: "agy")) == .antigravity)
        #expect(AgentKind.of(try terminal("d")) == .shell)
    }

    @Test func ordering() throws {
        let list = [
            try terminal("shell"),
            try terminal("idle", state: "idle", statusMs: 900),
            try terminal("workOld", state: "working", statusMs: 100),
            try terminal("blocked", state: "blocked", statusMs: 50),
            try terminal("workNew", state: "working", statusMs: 200),
        ]
        #expect(AgentsOrdering.ordered(list).map(\.address) == ["blocked", "workNew", "workOld", "idle", "shell"])
    }
}
