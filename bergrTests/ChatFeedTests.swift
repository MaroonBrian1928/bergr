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

    @Test func usageWaitsForCaughtUpAndRetainsSourceTime() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [reset,
            #"{"t":"usage","used":1000,"observed_at":1799999000,"weekly":{"percent":95,"resets_at":1800000000}}"#])
        #expect(feed.usage?.observedAt == Date(timeIntervalSince1970: 1_799_999_000))
        #expect(UsageReadings.currentUsage(feed) == nil)
        _ = try await run(feed, lines: [#"{"t":"ping"}"#])
        #expect(UsageReadings.currentUsage(feed)?.weekly?.percent == 95)
    }

    @Test func noneShowsNoConversationWithoutPings() async throws {
        let feed = ChatFeed()
        _ = try await run(feed, lines: [#"{"t":"none"}"#])
        #expect(feed.phase == .noConversation)
    }
}

@MainActor
struct ChatFeedRecoveryTests {
    private let launch = ChatHelperLaunch.Plan(command: "test", input: Data(), sourceLine: Data())

    private final class Transport: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts = 0
        private var closedIDs: Set<Int> = []
        private var opensEntered = 0
        private var writes = 0
        private var continuations: [AsyncThrowingStream<Data, Error>.Continuation] = []
        var count: Int { lock.withLock { attempts } }
        var closed: Int { lock.withLock { closedIDs.count } }
        func isClosed(_ id: Int) -> Bool { lock.withLock { closedIDs.contains(id) } }
        var openCount: Int { lock.withLock { opensEntered } }
        func enteredOpen() { lock.withLock { opensEntered += 1 } }
        var writeCount: Int { lock.withLock { writes } }
        func pipe(fail: Bool = false, traffic: Bool = false, needSource: Bool = false,
                  write: @escaping @Sendable (Data) async throws -> Void = { _ in }) -> ExecPipe {
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            let id = lock.withLock {
                attempts += 1
                continuations.append(continuation)
                return attempts
            }
            if fail { continuation.finish(throwing: CancellationError()) }
            if needSource { continuation.yield(Data("{\"t\":\"need-source\"}\n".utf8)) }
            if traffic {
                Task {
                    while !Task.isCancelled {
                        if case .terminated = continuation.yield(Data("{\"t\":\"cursor\"}\n".utf8)) { return }
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
            }
            return ExecPipe(output: stream, write: { [self] data in
                lock.withLock { writes += 1 }
                try await write(data)
            }, close: { [self] in
                lock.withLock { _ = closedIDs.insert(id) }
                continuation.finish(throwing: CancellationError())
            })
        }
    }

    private actor Gate {
        private var continuations: [CheckedContinuation<Void, Never>] = []
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() { released = true; continuations.forEach { $0.resume() }; continuations = [] }
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test func channelCancellationRetriesAndOwnerCancellationCloses() async {
        let transport = Transport(), feed = ChatFeed(), launch = launch
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.pipe(fail: transport.count == 0)
        }, timeout: .seconds(1), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.count >= 2 })
        task.cancel()
        await task.value
        #expect(transport.isClosed(2))
        let attempts = transport.count
        try? await Task.sleep(for: .milliseconds(30))
        #expect(transport.count == attempts)
    }

    @Test func stuckInitialWriteRetries() async {
        let transport = Transport(), gate = Gate(), feed = ChatFeed(), launch = launch
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.pipe(write: { _ in await gate.wait() })
        }, timeout: .milliseconds(30), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.count >= 2 })
        task.cancel()
        await task.value
        await gate.release()
        #expect(transport.isClosed(2))
    }

    @Test func cancellingStuckWriteClosesPromptly() async {
        let transport = Transport(), gate = Gate(), feed = ChatFeed(), launch = launch
        var finished = false
        let task = Task {
            await feed.run(makeLaunch: { launch }, open: { _ in
                transport.pipe(write: { _ in await gate.wait() })
            }, timeout: .seconds(10), retryDelay: .milliseconds(1))
            finished = true
        }
        #expect(await waitUntil { transport.writeCount > 0 })
        task.cancel()
        #expect(await waitUntil { finished })
        #expect(transport.closed > 0)
        await gate.release()
        await task.value
        #expect(transport.count == 1)
    }

    @Test func stuckSourceUploadRetries() async {
        let transport = Transport(), gate = Gate(), feed = ChatFeed(), launch = launch
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.pipe(needSource: true, write: { _ in
                if transport.writeCount % 2 == 0 { await gate.wait() }
            })
        }, timeout: .milliseconds(40), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.count >= 2 })
        task.cancel()
        await gate.release()
        await task.value
        #expect(transport.isClosed(2))
    }

    @Test func cancelledOpenClosesLatePipe() async {
        let transport = Transport(), gate = Gate(), feed = ChatFeed(), launch = launch
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.enteredOpen()
            await gate.wait()
            return transport.pipe()
        }, timeout: .seconds(1), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.openCount > 0 })
        task.cancel()
        await task.value
        await gate.release()
        #expect(await waitUntil { transport.closed > 0 })
        #expect(transport.count == 1)
    }

    @Test func trafficWithoutReadinessStillRetriesAndKeepsDisplayedItems() async {
        let transport = Transport(), feed = ChatFeed(), launch = launch
        feed.loadEvents([["t": "msg", "id": "old", "role": "user", "text": "kept"]])
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.pipe(traffic: true)
        }, timeout: .milliseconds(40), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.count >= 2 })
        #expect(feed.items.map(\.id) == ["old"])
        task.cancel()
        await task.value
    }

    @Test func initialReadTimeoutReplacesSpinnerWhileRetrying() async {
        let transport = Transport(), feed = ChatFeed(), launch = launch
        let task = Task { await feed.run(makeLaunch: { launch }, open: { _ in
            transport.pipe(traffic: true)
        }, timeout: .milliseconds(40), retryDelay: .milliseconds(1)) }
        #expect(await waitUntil { transport.count >= 2 })
        if case .failed = feed.phase {} else {
            Issue.record("Timed-out initial load must show a failure instead of an endless spinner")
        }
        task.cancel()
        await task.value
    }
}
