import Foundation
import Testing
@testable import bergr

@MainActor
struct UsageHistoryTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let reset = Date(timeIntervalSince1970: 1_800_018_000)

    func reading(_ percent: Double, machine: String = "mac", weekly: Double? = nil) -> UsageReading {
        let usage = ChatFeed.Usage(model: nil, effort: nil, used: 1, limit: 100,
                                   session: .init(percent: percent, resetsAt: reset),
                                   weekly: weekly.map { .init(percent: $0, resetsAt: reset) })
        return UsageReading(id: "\(machine)/1", machine: machine, agent: .claude, running: true, usage: usage)
    }

    func points(_ values: [Double], step: TimeInterval = 600) -> [(date: Date, percent: Double)] {
        values.enumerated().map { (now.addingTimeInterval(-step * Double(values.count - 1 - $0.offset)), $0.element) }
    }

    @Test func recordingIsThrottledPerWindow() {
        let h = UsageHistory(url: nil)
        #expect(h.record([reading(10, weekly: 5)], now: now))
        #expect(h.entries.count == 2)
        #expect(!h.record([reading(11, weekly: 6)], now: now.addingTimeInterval(299)))
        #expect(h.record([reading(12, weekly: 7)], now: now.addingTimeInterval(300)))
        #expect(h.entries.count == 4)
        // Another machine has its own windows.
        #expect(h.record([reading(12, machine: "pi")], now: now.addingTimeInterval(301)))
    }

    @Test func prunesAfterThirtyDaysAndPersists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let h = UsageHistory(url: url)
        h.record([reading(10)], now: now)
        h.record([reading(20)], now: now.addingTimeInterval(31 * 86400))
        #expect(h.entries.map(\.percent) == [20])
        #expect(UsageHistory(url: url).entries.map(\.percent) == [20])
    }

    @Test func forecastRisingHitsLimit() {
        // 10 percent per 10 minutes, 50% now: 50 minutes to go.
        let f = UsageForecast.make(points: points([30, 40, 50]), resetsAt: now.addingTimeInterval(7200), now: now)
        #expect(f == .hitsLimit(now.addingTimeInterval(3000)))
    }

    @Test func forecastResetBeforeLimit() {
        let r = now.addingTimeInterval(600)
        #expect(UsageForecast.make(points: points([30, 40, 50]), resetsAt: r, now: now) == .resetsFirst(r))
    }

    @Test func forecastNeedsRisingAndThreePoints() {
        #expect(UsageForecast.make(points: points([50, 50, 50]), resetsAt: nil, now: now) == .none)
        #expect(UsageForecast.make(points: points([60, 50, 40]), resetsAt: nil, now: now) == .none)
        #expect(UsageForecast.make(points: points([40, 50]), resetsAt: nil, now: now) == .none)
        // Older than an hour does not count.
        #expect(UsageForecast.make(points: points([10, 20, 30], step: 3600), resetsAt: nil, now: now) == .none)
    }

    @Test func snapshotRoundTripsAndPicksHighest() throws {
        let s = UsageSnapshot(windows: [.init(title: "A", percent: 20, detail: ""),
                                        .init(title: "B", percent: 85, detail: "Limit at 15:10")], updated: now)
        let back = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.highest?.title == "B")
    }

    @Test func alertTextCarriesForecast() {
        let h = UsageHistory(url: nil)
        for (i, p) in [60.0, 70, 80].enumerated() {
            h.record([reading(p)], now: now.addingTimeInterval(Double(i - 2) * 600))
        }
        let tracker = UsageAlertTracker(defaults: nil, history: h)
        let alerts = tracker.alerts(for: [reading(80)], now: now)
        #expect(alerts.count == 1)
        #expect(alerts[0].body.contains("at this rate, limit at"))
        let plain = UsageAlertTracker(defaults: nil).alerts(for: [reading(80)], now: now)
        #expect(!plain[0].body.contains("at this rate"))
    }
}
