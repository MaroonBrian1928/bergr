import Foundation
import Testing
@testable import bergr

@MainActor
struct UsageTests {
    let now = Date(timeIntervalSince1970: 1_799_999_000)
    let resetA = Date(timeIntervalSince1970: 1_800_000_000)
    let resetB = Date(timeIntervalSince1970: 1_800_018_000)

    func window(_ percent: Double, _ reset: Date?) -> ChatFeed.Usage.Window {
        ChatFeed.Usage.Window(percent: percent, resetsAt: reset)
    }

    func usage(session: ChatFeed.Usage.Window? = nil, weekly: ChatFeed.Usage.Window? = nil,
               observedAt: Date? = nil) -> ChatFeed.Usage {
        ChatFeed.Usage(model: "claude-opus-5-5", effort: nil, used: 1000, limit: 200_000,
                       session: session, weekly: weekly, observedAt: observedAt)
    }

    func evaluate(_ tracker: UsageAlertTracker, _ readings: [UsageReading]) -> [UsageAlert] {
        tracker.alerts(for: readings, now: now)
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
        let tracker = UsageAlertTracker(defaults: nil)
        let before = [reading("a/t1", machine: "Mac", usage: usage(weekly: window(79, resetB)))]
        #expect(evaluate(tracker, before).isEmpty)

        let crossed = [reading("a/t1", machine: "Mac", usage: usage(weekly: window(80, resetB)))]
        let first = evaluate(tracker, crossed)
        #expect(first.count == 1)
        #expect(first[0].body.hasPrefix("Claude on Mac: weekly limit at 80%, resets "))

        // Still over the line in the same window: no repeat.
        #expect(evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(weekly: window(91, resetB)))]).isEmpty)

        // The window resets (lower percent, new reset time): armed again, fires on the next crossing.
        #expect(evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(weekly: window(5, resetA)))]).isEmpty)
        let again = evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(weekly: window(85, resetA)))])
        #expect(again.count == 1)
    }

    @Test func newResetTimeAloneRearmsTheWindow() {
        let tracker = UsageAlertTracker(defaults: nil)
        _ = evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetA)))])
        #expect(evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetA)))]).isEmpty)
        let next = evaluate(tracker, [reading("a/t1", machine: "Mac", usage: usage(session: window(82, resetB)))])
        #expect(next.count == 1)
    }

    @Test func sessionAndWeeklyWindowsAlertSeparately() {
        let tracker = UsageAlertTracker(defaults: nil)
        let both = [reading("a/t1", machine: "Mac", usage: usage(session: window(85, resetA), weekly: window(88, resetB)))]
        let alerts = evaluate(tracker, both)
        #expect(alerts.count == 2)
        #expect(alerts.contains { $0.body.contains("session limit at 85%") })
        #expect(alerts.contains { $0.body.contains("weekly limit at 88%") })
        #expect(evaluate(tracker, both).isEmpty)
    }

    @Test func sharedAccountAlertsOnceAcrossMachines() {
        let tracker = UsageAlertTracker(defaults: nil)
        let shared = usage(weekly: window(81, resetB))
        let alerts = evaluate(tracker, [
            reading("a/t1", machine: "Mac", usage: shared),
            reading("b/t1", machine: "Pi", usage: shared),
        ])
        #expect(alerts.count == 1)
        #expect(alerts[0].body.hasPrefix("Claude on Mac:"))
    }

    @Test func notRunningAgentsNeverAlert() {
        let tracker = UsageAlertTracker(defaults: nil)
        #expect(evaluate(tracker, [reading("a/t1", machine: "Mac", usage: nil)]).isEmpty)
    }
    @Test func percentageCorrectionsNeverRearmTheSameWindow() {
        let tracker = UsageAlertTracker(defaults: nil)
        for (percent, count) in [(85.0, 1), (79.0, 0), (86.0, 0), (100.0, 0)] {
            #expect(evaluate(tracker, [reading("a", machine: "Lab", usage: usage(weekly: window(percent, resetA)))]).count == count)
        }
    }

    @Test func codexRequiresFreshSourceTimestamp() {
        let tracker = UsageAlertTracker(defaults: nil)
        for observed in [nil, now.addingTimeInterval(-901), now.addingTimeInterval(61)] {
            let sample = reading("a", machine: "Lab", agent: .codex,
                                 usage: usage(weekly: window(95, resetA), observedAt: observed))
            #expect(evaluate(tracker, [sample]).isEmpty)
        }
        let fresh = reading("a", machine: "Lab", agent: .codex,
                            usage: usage(weekly: window(95, resetA), observedAt: now))
        #expect(evaluate(tracker, [fresh]).count == 1)
    }

    @Test func expiredUnknownAndInvalidWindowsNeverAlert() {
        let tracker = UsageAlertTracker(defaults: nil)
        for value in [window(95, now), window(95, now.addingTimeInterval(-1)), window(95, nil),
                      window(.nan, resetA), window(.infinity, resetA), window(101, resetA), window(-1, resetA)] {
            #expect(evaluate(tracker, [reading("a", machine: "Lab", usage: usage(weekly: value))]).isEmpty)
        }
        let stopped = UsageReading(id: "a", machine: "Lab", agent: .codex, running: false,
                                   usage: usage(weekly: window(95, resetA), observedAt: now))
        #expect(evaluate(tracker, [stopped]).isEmpty)
    }

    @Test func newestSharedSnapshotWinsInEitherOrder() {
        let old = reading("old", machine: "Old", agent: .codex,
                          usage: usage(weekly: window(95, resetA), observedAt: now.addingTimeInterval(-60)))
        let current = reading("new", machine: "New", agent: .codex,
                              usage: usage(weekly: window(20, resetA), observedAt: now))
        for readings in [[old, current], [current, old]] {
            let tracker = UsageAlertTracker(defaults: nil)
            #expect(evaluate(tracker, readings).isEmpty)
            // Closing the newer feed must not make its older, higher reading current again.
            #expect(evaluate(tracker, [old]).isEmpty)
            let crossed = reading("new", machine: "New", agent: .codex,
                                  usage: usage(weekly: window(85, resetA), observedAt: now.addingTimeInterval(1)))
            #expect(evaluate(tracker, [crossed]).count == 1)
        }
    }

    @Test func warningsAndNewestSnapshotsSurviveRelaunch() {
        let name = "UsageAlertsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let high = reading("a", machine: "Lab", agent: .codex,
                           usage: usage(weekly: window(85, resetA), observedAt: now))
        #expect(evaluate(UsageAlertTracker(defaults: defaults), [high]).count == 1)
        #expect(evaluate(UsageAlertTracker(defaults: defaults), [high]).isEmpty)

        // A newer low reading in another reset window is remembered even without an alert.
        let low = reading("b", machine: "Lab", agent: .codex,
                          usage: usage(session: window(20, resetB), observedAt: now))
        #expect(evaluate(UsageAlertTracker(defaults: defaults), [low]).isEmpty)
        let olderHigh = reading("b", machine: "Lab", agent: .codex,
                                usage: usage(session: window(90, resetB), observedAt: now.addingTimeInterval(-1)))
        #expect(evaluate(UsageAlertTracker(defaults: defaults), [olderHigh]).isEmpty)
    }

    @Test func aGenuinelyNewWindowCanAlertAndOldRecordsExpire() {
        let name = "UsageResetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let tracker = UsageAlertTracker(defaults: defaults)
        #expect(evaluate(tracker, [reading("a", machine: "Lab", usage: usage(weekly: window(85, resetA)))]).count == 1)
        let later = resetA.addingTimeInterval(1)
        let fresh = reading("a", machine: "Lab", agent: .codex,
                            usage: usage(weekly: window(85, resetB), observedAt: later))
        #expect(tracker.alerts(for: [fresh], now: later).count == 1)
        #expect(defaults.dictionary(forKey: UsageAlertTracker.storageKey)?.count == 1)
    }

    @Test func trackersInTwoWindowsShareTheLedgerImmediately() {
        let name = "UsageMultiWindowTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UsageAlertTracker(defaults: defaults)
        let second = UsageAlertTracker(defaults: defaults)
        let high = reading("a", machine: "Lab", agent: .codex,
                           usage: usage(weekly: window(85, resetA), observedAt: now))
        #expect(evaluate(first, [high]).count == 1)
        #expect(evaluate(second, [high]).isEmpty)
    }

}
