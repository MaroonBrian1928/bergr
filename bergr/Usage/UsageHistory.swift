import Foundation

/// A plan-usage forecast from recent readings of one window.
enum UsageForecast: Equatable {
    case hitsLimit(Date)
    /// The window resets before the limit would be reached.
    case resetsFirst(Date)
    /// Flat, falling or too few readings.
    case none

    static let lookback: TimeInterval = 60 * 60
    static let minimumPoints = 3

    /// A least-squares line over the last hour of `points` (of the current window).
    static func make(points: [(date: Date, percent: Double)], resetsAt: Date?, now: Date = .now) -> UsageForecast {
        let recent = points.filter { now.timeIntervalSince($0.date) <= lookback && $0.date <= now }
        guard recent.count >= minimumPoints, let last = recent.max(by: { $0.date < $1.date }) else { return .none }
        let t0 = recent.map(\.date).min()!.timeIntervalSince1970
        let xs = recent.map { $0.date.timeIntervalSince1970 - t0 }
        let ys = recent.map(\.percent)
        let n = Double(recent.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let denominator = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard denominator > 0 else { return .none }
        let slope = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / denominator
        guard slope > 0, slope.isFinite else { return .none }
        let seconds = max(0, (100 - last.percent) / slope)
        let hit = max(now, last.date.addingTimeInterval(seconds))
        if let resetsAt, resetsAt <= hit { return .resetsFirst(resetsAt) }
        return .hitsLimit(hit)
    }

    /// "15:10", or with the weekday when it is not today.
    static func clock(_ date: Date, now: Date = .now) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return date.formatted(.dateTime.hour().minute()) }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// The line the Usage screen shows.
    func sentence(now: Date = .now) -> String? {
        switch self {
        case .hitsLimit(let date): "At this rate you'll hit the limit at \(Self.clock(date, now: now))"
        case .resetsFirst(let date): "Resets at \(Self.clock(date, now: now))"
        case .none: nil
        }
    }

    /// The tail of the 80% alert.
    func alertSuffix(now: Date = .now) -> String? {
        guard case .hitsLimit(let date) = self else { return nil }
        return "at this rate, limit at \(Self.clock(date, now: now))"
    }
}

/// Plan-usage readings over time, per machine, agent and plan window ("session" or "weekly").
/// At most one reading per window every five minutes, kept 30 days in a JSON file.
@MainActor
final class UsageHistory {
    struct Entry: Codable, Equatable {
        /// "<machine>|<agent>|<kind>"
        var key: String
        var time: Date
        var percent: Double
        var resetsAt: Date?
    }

    static let interval: TimeInterval = 5 * 60
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    static let shared = UsageHistory(url: UsageHistory.defaultURL)
    nonisolated static var defaultURL: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("usage-history.json")
    }

    private(set) var entries: [Entry]
    private var lastTime: [String: Date] = [:]
    private let url: URL?

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = []
        }
        for entry in entries { lastTime[entry.key] = max(lastTime[entry.key] ?? .distantPast, entry.time) }
    }

    static func key(machine: String, agent: String, kind: String) -> String { "\(machine)|\(agent)|\(kind)" }

    /// Records the readings' plan windows that are due. Returns whether anything was added.
    @discardableResult
    func record(_ readings: [UsageReading], now: Date = .now) -> Bool {
        var added = false
        for reading in readings {
            guard reading.running, let usage = reading.usage else { continue }
            for (kind, window) in [("session", usage.session), ("weekly", usage.weekly)] {
                guard let window, window.percent.isFinite, (0...100).contains(window.percent) else { continue }
                let key = Self.key(machine: reading.machine, agent: reading.agent.rawValue, kind: kind)
                if let last = lastTime[key], now.timeIntervalSince(last) < Self.interval { continue }
                entries.append(Entry(key: key, time: now, percent: window.percent, resetsAt: window.resetsAt))
                lastTime[key] = now
                added = true
            }
        }
        let before = entries.count
        prune(now: now)
        if added || entries.count != before { save() }
        return added
    }

    func prune(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        entries.removeAll { $0.time < cutoff }
    }

    func entries(key: String, since: Date) -> [Entry] {
        entries.filter { $0.key == key && $0.time >= since }.sorted { $0.time < $1.time }
    }

    /// The forecast for the window's current run (same reset time), counting the live reading.
    func forecast(key: String, window: ChatFeed.Usage.Window, now: Date = .now) -> UsageForecast {
        var points = entries(key: key, since: now.addingTimeInterval(-UsageForecast.lookback))
            .filter { $0.resetsAt == window.resetsAt }
            .map { (date: $0.time, percent: $0.percent) }
        if points.last.map({ $0.date < now }) ?? true { points.append((now, window.percent)) }
        return UsageForecast.make(points: points, resetsAt: window.resetsAt, now: now)
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension UsageSnapshot {
    /// The widget's windows from the current readings, one per plan account and window.
    @MainActor
    static func make(readings: [UsageReading], history: UsageHistory, now: Date = .now) -> UsageSnapshot {
        var windows: [Window] = []
        for account in UsageAccounts.group(readings) {
            guard let reading = account.readings.first else { continue }
            for (kind, window) in [("session", account.session), ("weekly", account.weekly)] {
                guard let window else { continue }
                let key = UsageHistory.key(machine: reading.machine, agent: reading.agent.rawValue, kind: kind)
                var detail = ""
                switch history.forecast(key: key, window: window, now: now) {
                case .hitsLimit(let date): detail = "Limit at \(UsageForecast.clock(date, now: now))"
                case .resetsFirst(let date): detail = "Resets at \(UsageForecast.clock(date, now: now))"
                case .none:
                    if let reset = window.resetsAt { detail = "Resets at \(UsageForecast.clock(reset, now: now))" }
                }
                windows.append(Window(title: "\(reading.agent.displayName) \(kind)", percent: window.percent, detail: detail))
            }
        }
        return UsageSnapshot(windows: windows, updated: now)
    }
}
