import Testing
@testable import HerdrKit

@MainActor
struct TerminalInputQueueTests {
    @Test func suspendedReplyCannotInterleaveWithAnotherWindow() async {
        let queue = TerminalInputQueue()
        var events: [String] = []
        var release: CheckedContinuation<Void, Never>?
        let first = Task {
            await queue.run {
                events.append("A text")
                await withCheckedContinuation { release = $0 }
                events.append("A enter")
            }
        }
        while release == nil { await Task.yield() }
        let second = Task {
            await queue.run {
                events.append("B text")
                events.append("B enter")
            }
        }
        // Give the second viewer time to enter the queue while the first is suspended.
        for _ in 0..<10 { await Task.yield() }
        #expect(events == ["A text"])
        release?.resume()
        await first.value
        await second.value
        #expect(events == ["A text", "A enter", "B text", "B enter"])
        await queue.run { events.append("C") }
        #expect(events.last == "C")
    }
}
