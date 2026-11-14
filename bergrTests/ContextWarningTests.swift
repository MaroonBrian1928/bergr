import Foundation
import Testing
@testable import bergr

@MainActor
struct ContextWarningTests {
    func reading(_ id: String, used: Int, agent: ChatAgent = .claude) -> UsageReading {
        UsageReading(id: id, machine: "Lab", agent: agent, running: true,
                     usage: ChatFeed.Usage(model: nil, effort: nil, used: used, limit: 1000))
    }

    @Test func firesOncePerCrossingAndRearmsBelowSeventy() {
        let tracker = ContextAlertTracker()
        #expect(tracker.alerts(for: [reading("a/1", used: 850)]).isEmpty)
        let first = tracker.alerts(for: [reading("a/1", used: 920)])
        #expect(first.map(\.body) == ["Claude on Lab is at 92% context"])
        #expect(tracker.alerts(for: [reading("a/1", used: 950)]).isEmpty)
        // Between 70 and 90 does not re-arm.
        #expect(tracker.alerts(for: [reading("a/1", used: 750)]).isEmpty)
        #expect(tracker.alerts(for: [reading("a/1", used: 910)]).isEmpty)
        // After a compaction it does.
        #expect(tracker.alerts(for: [reading("a/1", used: 100)]).isEmpty)
        #expect(tracker.alerts(for: [reading("a/1", used: 900)]).count == 1)
    }

    @Test func agentsAreIndependent() {
        let tracker = ContextAlertTracker()
        #expect(tracker.alerts(for: [reading("a/1", used: 950), reading("a/2", used: 950, agent: .codex)]).count == 2)
        #expect(tracker.alerts(for: [reading("a/1", used: 950), reading("a/2", used: 950)]).isEmpty)
    }

    @Test func parsesReadingId() {
        let id = UUID()
        let parts = ContextAlertTracker.parts(of: "\(id.uuidString)/w1/t2")
        #expect(parts?.host == id && parts?.address == "w1/t2")
    }

    @Test func chipOnlyAtNinetyIdleAndSupported() {
        #expect(ContextWarning.suggestsCompact(fraction: 0.9, state: "idle", agent: .claude))
        #expect(ContextWarning.suggestsCompact(fraction: 0.95, state: "done", agent: .codex))
        #expect(!ContextWarning.suggestsCompact(fraction: 0.89, state: "idle", agent: .claude))
        #expect(!ContextWarning.suggestsCompact(fraction: nil, state: "idle", agent: .claude))
        #expect(!ContextWarning.suggestsCompact(fraction: 0.95, state: "working", agent: .claude))
        #expect(!ContextWarning.suggestsCompact(fraction: 0.95, state: "blocked", agent: .claude))
        #expect(!ContextWarning.suggestsCompact(fraction: 0.95, state: "idle", agent: .antigravity))
    }
}
