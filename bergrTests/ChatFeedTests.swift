import Foundation
import Testing
@testable import bergr

@MainActor
struct ChatFeedTests {
    @Test func sessionHintFromClaudeArgv() {
        #expect(ChatAgent.sessionHint(argv: ["claude", "--resume", "abc-123"]) == "abc-123")
        #expect(ChatAgent.sessionHint(argv: ["/usr/bin/claude", "-r", "abc-123", "--model", "x"]) == "abc-123")
        #expect(ChatAgent.sessionHint(argv: ["node", "claude", "--session-id", "abc-123"]) == "abc-123")
        #expect(ChatAgent.sessionHint(argv: ["claude", "--resume=abc-123"]) == "abc-123")
    }

    @Test func sessionHintFromCodexArgv() {
        #expect(ChatAgent.sessionHint(argv: ["codex", "resume", "abc-123"]) == "abc-123")
        #expect(ChatAgent.sessionHint(argv: ["node", "/opt/bin/codex", "resume", "abc-123"]) == "abc-123")
    }

    @Test func noSessionHint() {
        #expect(ChatAgent.sessionHint(argv: ["claude"]) == nil)
        #expect(ChatAgent.sessionHint(argv: ["claude", "--resume"]) == nil)
        #expect(ChatAgent.sessionHint(argv: ["claude", "-r", "--model"]) == nil)
        #expect(ChatAgent.sessionHint(argv: ["codex"]) == nil)
        #expect(ChatAgent.sessionHint(argv: ["codex", "resume", "--last"]) == nil)
        #expect(ChatAgent.sessionHint(argv: ["vim", "-r", "abc"]) == nil)
        #expect(ChatAgent.sessionHint(argv: []) == nil)
    }

    private func plan(_ text: String, _ status: String) -> [String: Any] {
        ["t": "plan", "id": "plan", "steps": [["text": text, "status": status]]]
    }

    @Test func planReplacesAndMovesToEnd() {
        let feed = ChatFeed()
        feed.loadEvents([
            ["t": "msg", "id": "a", "role": "user", "text": "one"],
            plan("first", "pending"),
            ["t": "msg", "id": "b", "role": "assistant", "text": "two"],
            plan("second", "in_progress"),
        ])
        #expect(feed.items.map(\.id) == ["a", "b", "plan"])
        #expect(feed.items.last?.kind == .plan([.init(text: "second", status: "in_progress")]))
    }

    @Test func planKeepsIndexConsistent() {
        let feed = ChatFeed()
        feed.loadEvents([
            plan("p", "pending"),
            ["t": "msg", "id": "a", "role": "user", "text": "one"],
            plan("q", "completed"),
            ["t": "msg", "id": "a", "role": "user", "text": "edited"],
        ])
        #expect(feed.items.map(\.id) == ["a", "plan"])
        #expect(feed.items[0].kind == .user("edited"))
    }

    @Test func imageEventsDecode() {
        let feed = ChatFeed()
        let bytes = Data([1, 2, 3, 4])
        feed.loadEvents([
            ["t": "image", "id": "i1", "role": "user", "mime": "image/png", "data": bytes.base64EncodedString()],
            ["t": "image", "id": "i2", "role": "assistant", "mime": "image/png", "data": bytes.base64EncodedString()],
            ["t": "image", "id": "bad", "role": "user", "mime": "image/png", "data": "!!!"],
        ])
        #expect(feed.items.map(\.id) == ["i1", "i2"])
        #expect(feed.items[0].kind == .image(data: bytes, fromUser: true))
        #expect(feed.items[1].kind == .image(data: bytes, fromUser: false))
    }
}
