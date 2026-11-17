import Foundation
import Testing
@testable import bergr

private actor Gauge {
    private(set) var running = 0
    private(set) var peak = 0
    private(set) var results: [String: String] = [:]
    func start() { running += 1; peak = max(peak, running) }
    func end() { running -= 1 }
    func record(_ id: String, _ text: String) { results[id] = text }
}

private struct SlowSummarizer: DigestSummarizing {
    let gauge: Gauge
    let delay: Duration
    func summarize(_ context: DigestContext) async -> String? {
        await gauge.start()
        try? await Task.sleep(for: delay)
        await gauge.end()
        return "summary of \(context.title)"
    }
}

/// Never answers until released, and ignores cancellation: only the timeout can end its turn.
private struct HangingSummarizer: DigestSummarizing {
    let latch: TestLatch
    func summarize(_ context: DigestContext) async -> String? {
        await latch.wait()
        return "never"
    }
}

struct DigestDeliveryTests {
    func context(_ title: String, said: String = "Fixed the build. All green.") -> DigestContext {
        DigestContext(title: title, kind: .finished, lines: [DigestLine(role: .assistant, text: said)], statusMessage: nil)
    }

    @Test func concurrencyIsCappedAtTwo() async {
        let gauge = Gauge()
        let items = (0..<6).map { (id: "a\($0)", context: context("agent \($0)")) }
        await AwayDigest.summaries(items, summarizer: SlowSummarizer(gauge: gauge, delay: .milliseconds(60)),
                                   maxConcurrent: 2, timeout: .seconds(3)) { id, text in
            await gauge.record(id, text)
        }
        #expect(await gauge.peak == 2)
        #expect(await gauge.results.count == 6)
        #expect(await gauge.results["a3"] == "summary of agent 3")
    }

    @Test(.timeLimit(.minutes(1))) func slowSummarizerFallsBackAtTimeout() async {
        let gauge = Gauge()
        let items = [(id: "x", context: context("slow"))]
        let latch = TestLatch()
        // The summarizer is released only after `summaries` returns, so getting here proves the
        // timeout fell back without waiting for it (a hang fails on the time limit).
        await AwayDigest.summaries(items, summarizer: HangingSummarizer(latch: latch), maxConcurrent: 2,
                                   timeout: .milliseconds(100)) { id, text in await gauge.record(id, text) }
        latch.release()
        #expect(await gauge.results["x"] == "All green.")
    }

    @Test func inputIsCappedPerAgent() {
        let lines = (0..<30).map { DigestLine(role: .assistant, text: "line \($0) " + String(repeating: "x", count: 390)) }
        let c = DigestContext(title: "t", kind: .finished, lines: lines, statusMessage: nil)
        let material = AwayDigest.material(c)
        #expect(material.count <= AwayDigest.maxInputCharacters)
        // Newest lines are kept.
        #expect(material.contains("line 29 "))
        #expect(!material.contains("line 0 "))
    }

    @Test func statusMessageIsTheMaterialWithoutChat() {
        let c = DigestContext(title: "t", kind: .needsYou, lines: [], statusMessage: "Run tests?")
        #expect(AwayDigest.material(c) == "Run tests?")
    }
}
