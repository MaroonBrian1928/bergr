import Testing
import Foundation
@testable import bergr

struct InputLatencyTests {
    /// One keystroke per entry, each answered by output `ms` later; keys are a second apart.
    private func latency(echoes ms: [Int]) -> InputLatency {
        var l = InputLatency()
        var t = ContinuousClock.now
        for m in ms {
            l.sent(at: t)
            l.outputArrived(at: t + .milliseconds(m))
            t = t + .seconds(1)
        }
        return l
    }

    @Test func burstMakesOneSample() {
        var l = InputLatency()
        let base = ContinuousClock.now
        l.sent(at: base)
        l.sent(at: base + .milliseconds(10))
        l.sent(at: base + .milliseconds(20))
        l.outputArrived(at: base + .milliseconds(80))
        #expect(l.samples == [.milliseconds(80)])
    }

    @Test func outputWithoutKeyIsIgnored() {
        var l = InputLatency()
        l.outputArrived(at: ContinuousClock.now)
        #expect(l.samples.isEmpty)
    }

    @Test func staleOpenSampleIsDropped() {
        var l = InputLatency()
        let base = ContinuousClock.now
        l.sent(at: base)
        l.sent(at: base + .seconds(6))
        l.outputArrived(at: base + .seconds(6) + .milliseconds(50))
        #expect(l.samples == [.milliseconds(50)])
    }

    @Test func medianAndP95OnKnownSamples() {
        let l = latency(echoes: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        #expect(l.median == .milliseconds(55))
        #expect(l.p95 == .milliseconds(100))

        let twenty = latency(echoes: Array(1...20).map { $0 * 10 })
        #expect(twenty.median == .milliseconds(105))
        #expect(twenty.p95 == .milliseconds(190))
    }

    @Test func emptyHasNoStats() {
        let l = InputLatency()
        #expect(l.median == nil)
        #expect(l.p95 == nil)
    }

    @Test func windowCapsSamples() {
        let l = latency(echoes: Array(1...70))
        #expect(l.samples.count == InputLatency.window)
        #expect(l.samples.first == .milliseconds(7))
        #expect(l.samples.last == .milliseconds(70))
    }

    @Test func queuedBytesPeakAndRender() {
        var l = InputLatency()
        l.received(bytes: 100)
        l.received(bytes: 50)
        #expect(l.queuedBytes == 150)
        #expect(l.peakQueuedBytes == 150)
        l.rendered()
        #expect(l.queuedBytes == 0)
        #expect(l.peakQueuedBytes == 150)
        l.received(bytes: 30)
        #expect(l.queuedBytes == 30)
        #expect(l.peakQueuedBytes == 150)
    }

    @Test func latencyTextFormats() {
        #expect(Duration.milliseconds(80).latencyText == "80 ms")
        #expect(Duration.milliseconds(210).latencyText == "210 ms")
        #expect(Duration.milliseconds(1400).latencyText == "1.4 s")
        #expect(Duration.seconds(2).latencyText == "2.0 s")
    }
}

@MainActor
struct TerminalStatsTests {
    private func slow(_ count: Int) -> InputLatency {
        var l = InputLatency()
        var t = ContinuousClock.now
        for _ in 0..<count {
            l.sent(at: t)
            l.outputArrived(at: t + .milliseconds(1200))
            t = t + .seconds(2)
        }
        return l
    }

    private func fast(_ count: Int) -> InputLatency {
        var l = InputLatency()
        var t = ContinuousClock.now
        for _ in 0..<count {
            l.sent(at: t)
            l.outputArrived(at: t + .milliseconds(100))
            t = t + .seconds(1)
        }
        return l
    }

    @Test func updateStoresSummary() {
        let stats = TerminalStats()
        var l = fast(3)
        l.received(bytes: 2048)
        stats.update(key: "h|a", label: "build", latency: l)
        #expect(stats.terminals["h|a"] == TerminalStats.Summary(
            label: "build", median: .milliseconds(100), p95: .milliseconds(100), samples: 3, peakQueuedBytes: 2048
        ))
        stats.remove(key: "h|a")
        #expect(stats.terminals["h|a"] == nil)
    }

    @Test func slowLogFiresOnceAndRearms() {
        let stats = TerminalStats()
        stats.update(key: "k", label: "build", latency: slow(7))
        #expect(stats.slowLogs == 0)

        stats.update(key: "k", label: "build", latency: slow(8))
        #expect(stats.slowLogs == 1)
        stats.update(key: "k", label: "build", latency: slow(20))
        #expect(stats.slowLogs == 1)

        stats.update(key: "k", label: "build", latency: fast(20))
        stats.update(key: "k", label: "build", latency: slow(8))
        #expect(stats.slowLogs == 2)
    }

    @Test func rearmNeedsP95BelowHalfSecond() {
        let stats = TerminalStats()
        stats.update(key: "k", label: "build", latency: slow(8))
        // p95 of 0.6 s is still above the re-arm line, so no second log.
        var middling = InputLatency()
        var t = ContinuousClock.now
        for _ in 0..<8 {
            middling.sent(at: t)
            middling.outputArrived(at: t + .milliseconds(600))
            t = t + .seconds(1)
        }
        stats.update(key: "k", label: "build", latency: middling)
        stats.update(key: "k", label: "build", latency: slow(8))
        #expect(stats.slowLogs == 1)
    }
}
