import SwiftUI

/// Context and plan usage of every running agent, across machines, grouped by account.
struct UsageScreen: View {
    @Environment(HostStore.self) private var hosts
    let sessions: SessionStore?

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
            ForEach(accounts) { account in
                Section {
                    if let session = account.session { meter("Current session", session) }
                    if let weekly = account.weekly { meter("Weekly", weekly) }
                    ForEach(account.readings) { reading in
                        readingRow(reading)
                    }
                } header: {
                    Text(header(account))
                }
            }
        }
        .formStyle(.grouped)
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
                Text("Open the chat to read usage")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func meter(_ title: String, _ window: ChatFeed.Usage.Window) -> some View {
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
        }
        .padding(.vertical, 4)
    }
}
