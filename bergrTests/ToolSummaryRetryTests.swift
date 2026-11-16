import Foundation
import Testing
@testable import bergr

private actor RetryWriter: OnDeviceTextWriting {
    private var replies: [String?]
    private let latch: TestLatch?
    private(set) var calls = 0

    init(_ replies: [String?], latch: TestLatch? = nil) {
        self.replies = replies
        self.latch = latch
    }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        calls += 1
        if let latch { await latch.wait() }
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

@MainActor
struct ToolSummaryRetryTests {
    private let titles = ["Run the tests", "Fix the padding"]

    @Test func retriesNilThenStoresSummary() async {
        let writer = RetryWriter([nil, "Fix the padding"])
        let summaries = ToolOutputSummaries(writer: writer, stepsRetryBackoff: .zero)
        await summaries.requestSteps(id: "steps", titles: titles)
        #expect(summaries.summary(for: "steps") == "Fix the padding")
        #expect(await writer.calls == 2)
    }

    @Test func retriesEchoAndEmptyReply() async {
        let writer = RetryWriter(["counts: 4", "  ", "Run tests and fix padding"])
        let summaries = ToolOutputSummaries(writer: writer, stepsRetryBackoff: .zero)
        await summaries.requestSteps(id: "steps", titles: titles)
        #expect(summaries.summary(for: "steps") == "Run tests and fix padding")
        #expect(await writer.calls == 3)
    }

    @Test func exhaustedAttemptsCanBeRequestedAgain() async {
        let writer = RetryWriter([nil, nil, nil, "Check tests and fix padding"])
        let summaries = ToolOutputSummaries(writer: writer, stepsRetryBackoff: .zero)
        await summaries.requestSteps(id: "steps", titles: titles)
        #expect(summaries.summary(for: "steps") == nil)
        #expect(await writer.calls == 3)
        await summaries.requestSteps(id: "steps", titles: titles)
        #expect(summaries.summary(for: "steps") == "Check tests and fix padding")
        #expect(await writer.calls == 4)
    }

    @Test func successfulStepAndOutputSummariesAreCachedWithoutAStore() async {
        let writer = RetryWriter(["Run tests and fix padding", "Build passed"])
        let summaries = ToolOutputSummaries(writer: writer, stepsRetryBackoff: .zero)
        await summaries.requestSteps(id: "steps", titles: titles)
        await summaries.requestSteps(id: "steps", titles: titles)
        await summaries.request(id: "output", finished: true, name: "Bash", command: "build", output: "a\nb\nc\nd\ne")
        await summaries.request(id: "output", finished: true, name: "Bash", command: "build", output: "a\nb\nc\nd\ne")
        #expect(summaries.summary(for: "steps") == "Run tests and fix padding")
        #expect(summaries.summary(for: "output") == "Build passed")
        #expect(await writer.calls == 2)
    }

    @Test func cancellationDoesNotRetryOrKeepStaleSummaryAndReleasesGate() async {
        let latch = TestLatch()
        let writer = RetryWriter(["Should not be stored", "Check tests and fix padding"], latch: latch)
        let summaries = ToolOutputSummaries(writer: writer, stepsAttemptCount: 3, stepsRetryBackoff: .zero)
        let task = Task { await summaries.requestSteps(id: "cancelled", titles: titles) }
        await waitUntil { await writer.calls == 1 }
        task.cancel()
        latch.release()
        await task.value
        #expect(summaries.summary(for: "cancelled") == nil)
        #expect(await writer.calls == 1)

        await summaries.requestSteps(id: "next", titles: titles)
        #expect(summaries.summary(for: "next") == "Check tests and fix padding")
        #expect(await writer.calls == 2)
    }

    @Test func sameIDRequestsCoalesceWhileInFlight() async {
        let latch = TestLatch()
        let writer = RetryWriter(["Run tests and fix padding"], latch: latch)
        let summaries = ToolOutputSummaries(writer: writer, stepsRetryBackoff: .zero)
        let first = Task { await summaries.requestSteps(id: "steps", titles: titles) }
        await waitUntil { await writer.calls == 1 }
        await summaries.requestSteps(id: "steps", titles: titles)
        #expect(await writer.calls == 1)
        latch.release()
        await first.value
        #expect(summaries.summary(for: "steps") == "Run tests and fix padding")
    }
}
