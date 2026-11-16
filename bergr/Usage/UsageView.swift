import Charts
import SwiftUI

/// Context and plan usage of every running agent, across machines, grouped by account.
struct UsageScreen: View {
    @Environment(HostStore.self) private var hosts
    let sessions: SessionStore?
    @State private var range = HistoryRange.day

    enum HistoryRange: String, CaseIterable, Identifiable {
        case day = "24 hours", week = "7 days"
        var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 24 * 3600 : 7 * 24 * 3600 }
    }

    var body: some View {
        let readings = UsageReadings.readings(hosts: hosts.hosts, sessions: sessions)
        let accounts = UsageAccounts.group(readings)
        Form {
            if accounts.isEmpty {
                Section {
                    Text("No agents are running on your machines.")
                        .foregroundStyle(.secondary)
                }
            }
            if accounts.contains(where: { $0.session != nil || $0.weekly != nil }) {
                Section {
                    Picker("History", selection: $range) {
                        ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            ForEach(accounts) { account in
                Section {
                    if let session = account.session { meter("Current session", session, kind: "session", account: account) }
                    if let weekly = account.weekly { meter("Weekly", weekly, kind: "weekly", account: account) }
                    ForEach(account.readings) { reading in
                        readingRow(reading)
                    }
                } header: {
                    Text(header(account))
                }
            }
        }
        .formStyle(.grouped)
        // Agents whose chat isn't open are read once from their transcripts, on opening and
        // when the list of agents changes.
        .task(id: UsageReadings.targets(hosts: hosts.hosts, sessions: sessions).map(\.id)) {
            await UsageProbe.shared.refresh(UsageReadings.targets(hosts: hosts.hosts, sessions: sessions),
                                            minAge: UsageProbe.screenAge)
        }
        .navigationTitle("Usage")
        .inlineNavigationTitle()
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private func header(_ account: UsageAccount) -> String {
        guard let first = account.readings.first else { return "" }
        if account.readings.count == 1 { return "\(first.agent.displayName) on \(first.machine)" }
        return "\(first.agent.displayName) · \(account.readings.map(\.machine).joined(separator: ", "))"
    }

    private func readingRow(_ reading: UsageReading) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(reading.agent.displayName) on \(reading.machine)")
            if let usage = reading.usage, reading.running {
                let model = usage.modelName ?? reading.agent.displayName
                let context = usage.limit.map { "\(UsageSheet.tokens(usage.used)) of \(UsageSheet.tokens($0)) tokens" }
                    ?? "\(UsageSheet.tokens(usage.used)) tokens"
                Text("\(model) · context \(context)")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Text(reading.failed ? "Couldn't read usage"
                     : reading.empty ? "No usage recorded yet" : "Reading usage…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func meter(_ title: String, _ window: ChatFeed.Usage.Window, kind: String, account: UsageAccount) -> some View {
        let key = account.readings.first.map { UsageHistory.key(machine: $0.machine, agent: $0.agent.rawValue, kind: kind) }
        return meter(title, window, key: key)
    }

    private func meter(_ title: String, _ window: ChatFeed.Usage.Window, key: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(window.percent.rounded()))% used").foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(1, window.percent / 100))
                .tint(window.percent >= 80 ? .red : .blue)
            if let resets = window.resetsAt {
                Text("Resets \(resets.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let key {
                if let forecast = UsageHistory.shared.forecast(key: key, window: window).sentence() {
                    Text(forecast).font(.footnote).foregroundStyle(.secondary)
                }
                UsageHistoryChart(
                    entries: UsageHistory.shared.entries(key: key, since: Date.now.addingTimeInterval(-range.seconds)),
                    range: range.seconds)
            }
        }
        .padding(.vertical, 4)
    }
}

/// A plan window's readings over the chosen range: percent used against time.
struct UsageHistoryChart: View {
    let entries: [UsageHistory.Entry]
    let range: TimeInterval

    var body: some View {
        if entries.count < 2 {
            Text("Not enough history yet").font(.footnote).foregroundStyle(.tertiary)
        } else {
            Chart {
                // Where the window reset: a dashed line at each reading after a drop.
                ForEach(Self.resets(entries), id: \.self) { time in
                    RuleMark(x: .value("Reset", time))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("Reset").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                ForEach(Self.segments(entries).indices, id: \.self) { i in
                    ForEach(Self.segments(entries)[i], id: \.time) { entry in
                        LineMark(x: .value("Time", entry.time), y: .value("Used", entry.percent),
                                 series: .value("Window", i))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(.tint)
                    }
                }
            }
            .chartXScale(domain: Date.now.addingTimeInterval(-range)...Date.now)
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                }
            }
            .frame(height: 100)
            .accessibilityLabel("Usage history")
        }
    }

    /// A drop of more than 5 points between readings is a reset (usage only goes up within a window).
    static func resets(_ entries: [UsageHistory.Entry]) -> [Date] {
        zip(entries, entries.dropFirst()).compactMap { a, b in b.percent < a.percent - 5 ? b.time : nil }
    }

    /// The readings split at each reset, so the line doesn't slope down across one.
    static func segments(_ entries: [UsageHistory.Entry]) -> [[UsageHistory.Entry]] {
        var out: [[UsageHistory.Entry]] = []
        for entry in entries {
            if let last = out.last?.last, entry.percent >= last.percent - 5 { out[out.count - 1].append(entry) }
            else { out.append([entry]) }
        }
        return out
    }
}
