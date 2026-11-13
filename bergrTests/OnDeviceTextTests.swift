import Foundation
import Testing
@testable import bergr

/// Holds every write until the test releases it, so tests control exactly how many are in flight.
actor HeldWriter: OnDeviceTextWriting {
    private(set) var prompts: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private let reply: String?

    init(reply: String? = "Fix flaky login test") { self.reply = reply }

    var active: Int { held.count }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        prompts.append(prompt)
        await withCheckedContinuation { held.append($0) }
        return reply
    }

    func releaseAll() {
        let all = held
        held.removeAll()
        for c in all { c.resume() }
    }
}

/// Polls `condition` (yielding) until it holds; fails the test after `limit`.
func waitUntil(_ limit: Duration = .seconds(5), _ condition: () async -> Bool) async {
    let end = ContinuousClock.now + limit
    while !(await condition()) {
        if ContinuousClock.now > end { Issue.record("Timed out waiting"); return }
        await Task.yield()
    }
}

/// Work that ignores cancellation until the test lets it go.
final class TestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var open = false

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if open { return true }
                waiter = c
                return false
            }
            if now { c.resume() }
        }
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            open = true
            defer { waiter = nil }
            return waiter
        }
        c?.resume()
    }
}

struct OnDeviceTextTests {
    @Test(arguments: [
        "I'm sorry, but I can't assist with that request.",
        "I’m sorry, I can’t help with that.",
        "I cannot help with that.",
        "I can't summarize this output.",
        "As an AI language model, I can't do that.",
        "I'm unable to provide a title.",
        "Sorry, I can't do that.",
        "\"I apologize, but I can't comply.\"",
        "Title: I'm sorry, but I cannot help.",
    ])
    func refusalsAreNil(_ reply: String) {
        #expect(OnDeviceText.isRefusal(reply.replacingOccurrences(of: "Title: ", with: "")))
        #expect(OnDeviceText.clean(reply) == nil)
        #expect(OnDeviceText.title(reply) == nil)
        #expect(FoundationModelsWriter.usable(reply.replacingOccurrences(of: "Title: ", with: ""), preserveLines: true) == nil)
    }

    @Test func normalReplySurvives() {
        #expect(OnDeviceText.clean("Ran 214 tests, 2 failed") == "Ran 214 tests, 2 failed")
        #expect(OnDeviceText.title("Fix sorry-path in login") == "Fix sorry-path in login")
        #expect(!OnDeviceText.isRefusal("Icons cannot load on startup"))
    }

    @Test func labelsAreStripped() {
        #expect(OnDeviceText.clean("Title: Fix flaky login test") == "Fix flaky login test")
        #expect(OnDeviceText.clean("**Summary:** \"All 12 tests passed\"") == "All 12 tests passed")
    }

    @Test func titlesRejectLongOrQuestions() {
        #expect(OnDeviceText.title("Could you share more details?") == nil)
        #expect(OnDeviceText.title("This is a title that has far too many words in it") == nil)
        #expect(OnDeviceText.title("Add dark mode to settings") == "Add dark mode to settings")
    }

    @Test func raceReturnsAtTheDeadlineWhenWorkIgnoresCancellation() async {
        let latch = TestLatch()
        let start = ContinuousClock.now
        let result: String? = await OnDeviceText.race(timeout: .milliseconds(100)) {
            await latch.wait()
            return "late"
        }
        let elapsed = ContinuousClock.now - start
        latch.release()
        #expect(result == nil)
        #expect(elapsed < .seconds(3))
    }

    @Test func raceReturnsTheAnswerInTime() async {
        let result: String? = await OnDeviceText.race(timeout: .seconds(10)) { "done" }
        #expect(result == "done")
    }

    @Test func raceReturnsPromptlyWhenTheCallerIsCancelled() async {
        let latch = TestLatch()
        let start = ContinuousClock.now
        let task = Task { () -> String? in
            await OnDeviceText.race(timeout: .seconds(60)) {
                await latch.wait()
                return "late"
            }
        }
        task.cancel()
        let result = await task.value
        let elapsed = ContinuousClock.now - start
        latch.release()
        #expect(result == nil)
        #expect(elapsed < .seconds(3))
    }
}

@MainActor
struct ToolSummaryCancelTests {
    @Test func cancelledWhileQueuedIsAskedAgain() async {
        let writer = HeldWriter(reply: "Ran 3 tests, all passed")
        let summaries = ToolOutputSummaries(writer: writer)
        let output = "a\nb\nc\nd\ne"
        let busy = (0..<ToolOutputSummaries.concurrent).map { i in
            Task { @MainActor in
                await summaries.request(id: "b\(i)", finished: true, name: "Bash", command: "c", output: output)
            }
        }
        await waitUntil { await writer.active == ToolOutputSummaries.concurrent }
        let queued = Task { @MainActor in
            await summaries.request(id: "q", finished: true, name: "Bash", command: "queued", output: output)
        }
        await waitUntil { await summaries.waitingCount == 1 }
        queued.cancel()
        await queued.value
        await writer.releaseAll()
        for task in busy { await task.value }
        #expect(await writer.prompts.allSatisfy { !$0.contains("queued") })
        // The row came back: it is asked again and gets its summary.
        let again = Task { @MainActor in
            await summaries.request(id: "q", finished: true, name: "Bash", command: "queued", output: output)
        }
        await waitUntil { await writer.active == 1 }
        await writer.releaseAll()
        await again.value
        #expect(summaries.summary(for: "q") == "Ran 3 tests, all passed")
    }
}
