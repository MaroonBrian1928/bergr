import Foundation
import Testing
@testable import bergr

@MainActor
struct UsageTests {
    let resetA = Date(timeIntervalSince1970: 1_800_000_000)
    let resetB = Date(timeIntervalSince1970: 1_800_018_000)

    func window(_ percent: Double, _ reset: Date?) -> ChatFeed.Usage.Window {
        ChatFeed.Usage.Window(percent: percent, resetsAt: reset)
    }

    func usage(session: ChatFeed.Usage.Window? = nil, weekly: ChatFeed.Usage.Window? = nil) -> ChatFeed.Usage {
        ChatFeed.Usage(model: "claude-opus-5-5", effort: nil, used: 1000, limit: 200_000, session: session, weekly: weekly)
    }

    func reading(_ id: String, machine: String, agent: ChatAgent = .claude, usage: ChatFeed.Usage?) -> UsageReading {
        UsageReading(id: id, machine: machine, agent: agent, running: usage != nil, usage: usage)
    }

    // MARK: Grouping

    @Test func sameWindowOnTwoMachinesIsOneAccount() {
        let shared = usage(session: window(40, resetA), weekly: window(70, resetB))
        let accounts = UsageAccounts.group([
            reading("a/t1", machine: "Mac", usage: shared),
            reading("b/t1", machine: "Pi", usage: shared),
        ])
        #expect(accounts.count == 1)
        #expect(accounts[0].readings.map(\.machine) == ["Mac", "Pi"])
        #expect(accounts[0].weekly?.percent == 70)
    }

    @Test func differentPercentOrResetStaysSeparate() {
        let accounts = UsageAccounts.group([
            reading("a/t1", machine: "Mac", usage: usage(weekly: window(70, resetB))),
            reading("b/t1", machine: "Pi", usage: usage(weekly: window(71, resetB))),
            reading("c/t1", machine: "Box", usage: usage(weekly: window(70, resetA))),
        ])
        #expect(accounts.count == 3)
    }

    @Test func differentAgentsDoNotShareAnAccount() {
        let shared = usage(weekly: window(70, resetB))
        let accounts = UsageAccounts.group([
            reading("a/t1", machine: "Mac", agent: .claude, usage: shared),
            reading("a/t2", machine: "Mac", agent: .codex, usage: shared),
        ])
        #expect(accounts.count == 2)
    }

    @Test func agentsWithoutWindowsAreNeverMerged() {
        let accounts = UsageAccounts.group([
            reading("a/t1", machine: "Mac", usage: nil),
            reading("b/t1", machine: "Pi", usage: nil),
        ])
        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.readings.count == 1 && $0.session == nil && $0.weekly == nil })
    }

    // MARK: 80% alerts

    @Test func crossingFiresOnceAndAgainAfterReset() {
        let tracker = UsageAlertTracker()
        let before = [reading("a/t1", machine: "Mac", usage: usage(weekly: window(79, resetB)))]
        #expect(tracker.alerts(for: before).isEmpty)

        let crossed = [reading("a/t1", machine: "Mac", usage: usage(weekly: window(80, resetB)))]
        let first = tracker.alerts(for: crossed)
        #expect(first.count == 1)
        #expect(first[0].body.hasPrefix("Claude on Mac: weekly limit at 80%, resets "))

        // Still over the line in the same window: no repeat.
        #expect(tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(weekly: window(91, resetB)))]).isEmpty)

        // The window resets (lower percent, new reset time): armed again, fires on the next crossing.
        #expect(tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(weekly: window(5, resetA)))]).isEmpty)
        let again = tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(weekly: window(85, resetA)))])
        #expect(again.count == 1)
    }

    @Test func newResetTimeAloneRearmsTheWindow() {
        let tracker = UsageAlertTracker()
        _ = tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetA)))])
        #expect(tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetA)))]).isEmpty)
        let next = tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetB)))])
        #expect(next.count == 1)
    }

    @Test func sessionAndWeeklyWindowsAlertSeparately() {
        let tracker = UsageAlertTracker()
        let both = [reading("a/t1", machine: "Mac", usage: usage(session: window(85, resetA), weekly: window(88, resetB)))]
        let alerts = tracker.alerts(for: both)
        #expect(alerts.count == 2)
        #expect(alerts.contains { $0.body.contains("session limit at 85%") })
        #expect(alerts.contains { $0.body.contains("weekly limit at 88%") })
        #expect(tracker.alerts(for: both).isEmpty)
    }

    @Test func sharedAccountAlertsOnceAcrossMachines() {
        let tracker = UsageAlertTracker()
        let shared = usage(weekly: window(81, resetB))
        let alerts = tracker.alerts(for: [
            reading("a/t1", machine: "Mac", usage: shared),
            reading("b/t1", machine: "Pi", usage: shared),
        ])
        #expect(alerts.count == 1)
        #expect(alerts[0].body.hasPrefix("Claude on Mac:"))
    }

    @Test func notRunningAgentsNeverAlert() {
        let tracker = UsageAlertTracker()
        #expect(tracker.alerts(for: [reading("a/t1", machine: "Mac", usage: nil)]).isEmpty)
    }
}
