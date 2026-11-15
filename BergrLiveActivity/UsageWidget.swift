import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: UsageSnapshot(
            windows: [.init(title: "Claude session", percent: 62, detail: "Limit at 15:10")], updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: .now, snapshot: UsageSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        // The app reloads this when a reading changes; the date is only a fallback.
        completion(Timeline(entries: [UsageEntry(date: .now, snapshot: UsageSnapshot.load())],
                            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: UsageSnapshot.widgetKind, provider: UsageProvider()) { entry in
            UsageWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("The plan limit closest to running out, and when it will.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct UsageWidgetView: View {
    let snapshot: UsageSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let top = snapshot.highest {
            if family == .systemMedium {
                HStack(alignment: .top, spacing: 16) {
                    headline(top)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(snapshot.windows.sorted { $0.percent > $1.percent }.prefix(4).enumerated()), id: \.offset) { _, w in
                            HStack {
                                Text(w.title).lineLimit(1)
                                Spacer()
                                Text("\(Int(w.percent.rounded()))%").monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                }
            } else {
                headline(top)
            }
        } else {
            Text("No usage yet").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func headline(_ window: UsageSnapshot.Window) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(window.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(window.percent >= 80 ? Color.red : Color.primary)
            ProgressView(value: min(1, window.percent / 100)).tint(window.percent >= 80 ? .red : .blue)
            if !window.detail.isEmpty {
                Text(window.detail).font(.caption).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}
