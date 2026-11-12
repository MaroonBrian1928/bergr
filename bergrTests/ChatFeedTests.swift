import Foundation
import HerdrKit
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

    @Test func lazyImageIsAPlaceholderWithItsSize() {
        let feed = ChatFeed()
        feed.loadEvents([["t": "image", "id": "i1", "role": "assistant", "mime": "image/png", "lazy": true,
                          "size": 1234, "width": 3, "height": 2]])
        #expect(feed.items[0].kind == .imageOnDemand(size: 1234, width: 3, height: 2, fromUser: false, fetching: false))
    }
}

// MARK: Helper protocol: handshake, resume, cursor

@MainActor
struct ChatFeedProtocolTests {
    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func add(_ d: Data) { lock.withLock { data.append(d) } }
        var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    /// Runs one helper session: the lines it "prints", then it exits. Returns what the app wrote.
    private func run(_ feed: ChatFeed, lines: [String]) async throws -> String {
        let writes = Writes()
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let pipe = ExecPipe(output: stream, write: { writes.add($0) }, close: {})
        for line in lines { continuation.yield(Data((line + "\n").utf8)) }
        continuation.finish()
        let plan = try ChatHelperLaunch.make(script: "SOURCE", agent: "claude", pid: 0, cwd: "/w",
                                             sessionHint: nil, windows: false, stage2: "pass")
        try await feed.read(pipe, launch: plan)
        return writes.text
    }

    private func msg(_ id: String, _ text: String) -> String {
        #"{"t":"msg","id":"\#(id)","role":"user","text":"\#(text)"}"#
    }

    private let reset = #"{"t":"reset","agent":"claude","session":"s.jsonl"}"#

    @Test func needSourceIsAnsweredWithTheSource() async throws {
        let written = try await run(ChatFeed(), lines: [#"{"t":"need-source"}"#])
        #expect(written == Data("SOURCE".utf8).base64EncodedString() + "\n")
    }

    @Test func cachedHelperGetsNoSource() async throws {
        let written = try await run(ChatFeed(), lines: [reset, msg("a", "one"), #"{"t":"ping"}"#])
        #expect(written.isEmpty)
    }

    @Test func resumeKeepsWhatIsShownWithoutASwap() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [reset, msg("a", "one"), #"{"t":"ping"}"#,
                                        #"{"t":"cursor","session":"s.jsonl","offset":100}"#])
        #expect(feed.cursor == .init(session: "s.jsonl", offset: 100))
        #expect(feed.items.map(\.id) == ["a"])
        // Relaunched with the cursor: `resume` leaves the items alone and new ones are live.
        _ = try await run(feed, lines: [#"{"t":"resume"}"#, msg("b", "two")])
        #expect(feed.caughtUp)
        #expect(feed.items.map(\.id) == ["a", "b"])
        #expect(feed.cursor == .init(session: "s.jsonl", offset: 100))
    }

    @Test func resumeIsTheCaughtUpSignal() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [#"{"t":"resume"}"#, msg("b", "two")])
        #expect(feed.phase == .live)
        #expect(feed.caughtUp)
        #expect(feed.items.map(\.id) == ["b"])
    }

    @Test func resetAfterwardsRebuildsAndDropsTheCursor() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [reset, msg("a", "one"), #"{"t":"ping"}"#,
                                        #"{"t":"cursor","session":"s.jsonl","offset":100}"#])
        _ = try await run(feed, lines: [reset, msg("a", "one")])
        #expect(!feed.caughtUp)
        #expect(feed.cursor == nil)
        #expect(feed.items.map(\.id) == ["a"])  // still on screen until the first ping
    }

    @Test func clearSwitchesToEmptySessionAndDropsOldMessages() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [reset, msg("a", "previous conversation"), #"{"t":"ping"}"#])
        #expect(feed.items.count == 1)
        _ = try await run(feed, lines: [#"{"t":"reset","agent":"claude","session":"new.jsonl"}"#,
                                       #"{"t":"cursor","session":"new.jsonl","offset":0}"#,
                                       #"{"t":"ping"}"#])
        #expect(feed.conversationID == "new")
        #expect(feed.caughtUp)
        #expect(feed.items.isEmpty)
        #expect(feed.cursor == .init(session: "new.jsonl", offset: 0))
        _ = try await run(feed, lines: [#"{"t":"resume"}"#, msg("b", "fresh start")])
        #expect(feed.items.map(\.id) == ["b"])
    }

    @Test func noneShowsNoConversationWithoutPings() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [#"{"t":"none"}"#])
        #expect(feed.phase == .noConversation)
    }
}
