import Foundation
import Testing
@testable import bergr

@MainActor
struct UsageProbeTests {
    private let usageLine = #"{"t":"usage","model":"claude-opus-5-5","effort":null,"used":5010,"limit":200000,"#
        + #""session":{"percent":83.0,"resets_at":1800000000},"weekly":null}"#

    private func usage(_ percent: Double) -> ChatFeed.Usage {
        ChatFeed.Usage(model: "m", effort: nil, used: 1, limit: 10,
                       session: .init(percent: percent, resetsAt: Date(timeIntervalSince1970: 1_800_000_000)), weekly: nil)
    }

    private func target(_ id: String, working: Bool) -> UsageTarget {
        UsageTarget(id: id, agent: .claude, pid: 1, cwd: "/w", sessionHint: nil, working: working, session: nil)
    }

    /// Counts the reads and answers from a table; the clock is whatever the test sets.
    @MainActor private final class Rig {
        var reads: [String] = []
        var now = Date(timeIntervalSince1970: 1_000_000)
        var failing: Set<String> = []
        var answer: ChatFeed.Usage?
        lazy var probe = UsageProbe(runner: { [unowned self] target in
            reads.append(target.id)
            if failing.contains(target.id) { throw UsageProbeError.noAnswer }
            return answer
        }, clock: { [unowned self] in now })
    }

    // MARK: Parsing and launch

    @Test func parsesTheLastUsageLineAfterNoise() throws {
        let output = "Welcome to the machine\n{\"t\":\"need-source\"}\n\(usageLine)\n"
        let parsed = try #require(try UsageProbe.parse(output))
        #expect(parsed.used == 5010)
        #expect(parsed.limit == 200_000)
        #expect(parsed.session?.percent == 83)
        #expect(parsed.session?.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(parsed.weekly == nil)
    }

    @Test func noneMeansNothingYetAndGarbageThrows() throws {
        #expect(try UsageProbe.parse("{\"t\":\"none\"}\n") == nil)
        #expect(throws: UsageProbeError.self) { try UsageProbe.parse("python3: command not found\n") }
        #expect(throws: UsageProbeError.self) { try UsageProbe.parse("") }
    }

    @Test func oneShotLaunchAddsOnceAndSendsTheSource() throws {
        let plan = try ChatHelperLaunch.make(script: "x", agent: "codex", pid: 7, cwd: "/w", sessionHint: nil,
                                             windows: true, stage2: "pass", once: true)
        let line = String(decoding: plan.input, as: UTF8.self)
        let start = try #require(line.range(of: "b64decode('")).upperBound
        let end = try #require(line[start...].firstIndex(of: "'"))
        let data = try #require(Data(base64Encoded: String(line[start..<end])))
        let argv = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["argv"] as? [String])
        #expect(argv == ["agent-feed.py", "codex", "7", "/w", "-", "0", "-", "0", "once"])
        #expect(plan.command.hasPrefix("cmd /d /s /c "))
        // The following (follow) mode is unchanged.
        let follow = try ChatHelperLaunch.make(script: "x", agent: "codex", pid: 7, cwd: "/w", sessionHint: nil,
                                               windows: false, stage2: "pass")
        #expect(!String(decoding: follow.input, as: UTF8.self).isEmpty)
    }

    // MARK: Readings prefer the live feed

    @Test func liveFeedWinsOverTheOneShot() {
        let feed = ChatFeed()
        feed.loadEvents([["t": "usage", "model": "live", "used": 9, "limit": 100,
                          "session": ["percent": 10.0, "resets_at": 1_800_000_000]]])
        let r = UsageReadings.resolve(feed: feed, probed: .usage(usage(90)))
        #expect(r.running && r.usage?.session?.percent == 10)
    }

    @Test func oneShotFillsInWithoutAFeedOrBeforeTheFeedCatchesUp() {
        let r = UsageReadings.resolve(feed: nil, probed: .usage(usage(90)))
        #expect(r.running && r.usage?.session?.percent == 90)
        let loading = UsageReadings.resolve(feed: ChatFeed(), probed: .usage(usage(55)))
        #expect(loading.running && loading.usage?.session?.percent == 55)
    }

    @Test func failureAndEmptyAreFlaggedPerRow() {
        let failed = UsageReadings.resolve(feed: nil, probed: .failed)
        #expect(!failed.running && failed.usage == nil && failed.failed)
        let empty = UsageReadings.resolve(feed: nil, probed: .empty)
        #expect(!empty.running && !empty.failed && empty.empty)
        let waiting = UsageReadings.resolve(feed: nil, probed: nil)
        #expect(!waiting.running && !waiting.failed && !waiting.empty)
        // A running feed with no numbers yet is not a failure.
        let feed = UsageReadings.resolve(feed: ChatFeed(), probed: .failed)
        #expect(feed.running && !feed.failed)
    }

    @Test func aProbedReadingFeedsTheAlertTracker() {
        let defaults = UserDefaults(suiteName: "usage-probe-\(UUID().uuidString)")
        let tracker = UsageAlertTracker(defaults: defaults)
        let resolved = UsageReadings.resolve(feed: nil, probed: .usage(usage(85)))
        let reading = UsageReading(id: "h/t1", machine: "Pi", agent: .claude, running: resolved.running, usage: resolved.usage)
        let alerts = tracker.alerts(for: [reading], now: Date(timeIntervalSince1970: 1_799_999_000))
        #expect(alerts.count == 1)
    }

    // MARK: Polling

    @Test func throttlesToOneReadPerFiveMinutesPerAgent() async {
        let rig = Rig()
        rig.answer = usage(40)
        let a = target("a", working: true)
        await rig.probe.refresh([a], minAge: UsageProbe.pollInterval, onlyWorking: true)
        rig.now += 299
        await rig.probe.refresh([a], minAge: UsageProbe.pollInterval, onlyWorking: true)
        #expect(rig.reads == ["a"])
        rig.now += 2
        await rig.probe.refresh([a], minAge: UsageProbe.pollInterval, onlyWorking: true)
        #expect(rig.reads == ["a", "a"])
        #expect(rig.probe.outcomes["a"] == .usage(usage(40)))
    }

    @Test func pollsOnlyWorkingAgents() async {
        let rig = Rig()
        rig.answer = usage(40)
        await rig.probe.refresh([target("idle", working: false), target("busy", working: true)],
                                minAge: UsageProbe.pollInterval, onlyWorking: true)
        #expect(rig.reads == ["busy"])
        #expect(rig.probe.outcomes["idle"] == nil)
        // The Usage screen reads every agent, working or not.
        await rig.probe.refresh([target("idle", working: false)], minAge: UsageProbe.screenAge)
        #expect(rig.reads == ["busy", "idle"])
    }

    @Test func aFailedReadIsThatRowsOutcomeAndStillThrottled() async {
        let rig = Rig()
        rig.answer = usage(40)
        rig.failing = ["bad"]
        await rig.probe.refresh([target("bad", working: true), target("good", working: true)],
                                minAge: UsageProbe.pollInterval, onlyWorking: true)
        #expect(rig.probe.outcomes["bad"] == .failed)
        #expect(rig.probe.outcomes["good"] == .usage(usage(40)))
        await rig.probe.refresh([target("bad", working: true)], minAge: UsageProbe.pollInterval, onlyWorking: true)
        #expect(rig.reads.filter { $0 == "bad" }.count == 1)
    }

    @Test func nothingFoundIsEmptyNotFailed() async {
        let rig = Rig()
        await rig.probe.refresh([target("a", working: true)], minAge: 0)
        #expect(rig.probe.outcomes["a"] == .empty)
    }
}
