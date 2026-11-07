import SwiftUI
import WidgetKit

struct AgentsEntry: TimelineEntry {
    let date: Date
    let snapshot: AgentsSnapshot
}

struct AgentsProvider: TimelineProvider {
    func placeholder(in context: Context) -> AgentsEntry {
        AgentsEntry(date: .now, snapshot: AgentsSnapshot(needsYou: 1, working: 2, done: 1, rows: [], updated: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (AgentsEntry) -> Void) {
        completion(AgentsEntry(date: .now, snapshot: AgentsSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AgentsEntry>) -> Void) {
        // The app reloads this whenever the data changes; the date is only a fallback.
        completion(Timeline(
            entries: [AgentsEntry(date: .now, snapshot: AgentsSnapshot.load())],
            policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct AgentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BergrAppGroup.widgetKind, provider: AgentsProvider()) { entry in
            AgentsWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agents")
        .description("Which agents need you, are working, or are done.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct AgentsWidgetView: View {
    let snapshot: AgentsSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                counts
                Spacer(minLength: 0)
                if let row = snapshot.rows.first(where: \.needsYou) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(row.machine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(snapshot.working > 0 ? "Working" : "Nothing needs you")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(snapshot.rows.first(where: \.needsYou)?.url)
        } else {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents").font(.subheadline.weight(.semibold))
                    counts
                }
                VStack(alignment: .leading, spacing: 8) {
                    let needing = Array(snapshot.rows.filter(\.needsYou).prefix(3))
                    if needing.isEmpty {
                        Text(snapshot.working > 0 ? "\(snapshot.working) working" : "Nothing needs you")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(needing, id: \.url) { row in
                        Link(destination: row.url) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(Color.needsYou)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(row.status.isEmpty ? row.machine : "\(row.status) · \(row.machine)")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 4) {
            count(snapshot.needsYou, "exclamationmark.bubble.fill", "need you", .needsYou)
            count(snapshot.working, "circle.dotted", "working", .working)
            count(snapshot.done, "checkmark.circle.fill", "done", .done)
        }
    }

    private func count(_ n: Int, _ symbol: String, _ word: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            Text("\(n)").font(.callout.bold().monospacedDigit())
            Text(word).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
