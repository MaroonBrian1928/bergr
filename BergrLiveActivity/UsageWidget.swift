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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

/// Internal (not private) and with an optional `family`, so `scripts/site-widgets.sh` can render it
/// outside WidgetKit, where the environment's family can't be set.
struct UsageWidgetView: View {
    let snapshot: UsageSnapshot
    var familyOverride: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { familyOverride ?? environmentFamily }

    init(snapshot: UsageSnapshot, family: WidgetFamily? = nil) {
        self.snapshot = snapshot
        familyOverride = family
    }

    var body: some View {
        if let top = snapshot.highest {
            if family == .accessoryCircular {
                // Lock Screen: the closest limit as a ring, its percent inside.
                Gauge(value: min(100, top.percent), in: 0...100) {
                    Image(systemName: "gauge.with.dots.needle.50percent")
                } currentValueLabel: {
                    Text("\(Int(top.percent.rounded()))").font(.title3.bold().monospacedDigit())
                        .contentTransition(.numericText())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel("\(top.title) \(Int(top.percent.rounded())) percent used")
            } else if family == .accessoryRectangular {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(top.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(Int(top.percent.rounded()))%").monospacedDigit()
                    }
                    .font(.headline)
                    .widgetAccentable()
                    Gauge(value: min(100, top.percent), in: 0...100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                    if !top.detail.isEmpty { Text(top.detail).font(.caption).lineLimit(1) }
                }
            } else if family == .systemMedium {
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
                .contentTransition(.numericText())
                .minimumScaleFactor(0.7)
                .foregroundStyle(window.percent >= 80 ? Color.red : Color.primary)
            UsageBar(fraction: min(1, window.percent / 100), color: window.percent >= 80 ? .red : .blue)
            if !window.detail.isEmpty {
                Text(window.detail).font(.caption).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A thin capsule bar: looks like a linear ProgressView, but also draws in ImageRenderer (the site's
/// widget pictures), which leaves ProgressView empty.
private struct UsageBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule().fill(Color.secondary.opacity(0.25))
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(color).frame(width: g.size.width * max(0, fraction)) }
            }
            .frame(height: 4)
            .padding(.vertical, 4)
            .accessibilityElement()
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}
