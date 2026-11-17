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
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct AgentsWidgetView: View {
    let snapshot: AgentsSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryCircular {
            // The ring fills with the share of running agents that need you (it was always empty).
            let total = max(1, snapshot.needsYou + snapshot.working + snapshot.done)
            Gauge(value: Double(snapshot.needsYou), in: 0...Double(total)) {
                Image(systemName: "exclamationmark.bubble.fill")
            } currentValueLabel: {
                Text("\(snapshot.needsYou)").font(.title3.bold().monospacedDigit())
                    .contentTransition(.numericText())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .accessibilityLabel("\(snapshot.needsYou) agents need you")
        } else if family == .accessoryRectangular {
            let rows = AgentWidgetContent.activeRows(snapshot, limit: 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.needsYou > 0 ? "\(snapshot.needsYou) need you" : "Agents")
                    .font(.headline).widgetAccentable()
                if rows.isEmpty {
                    Text("Nothing needs you").font(.caption)
                }
                ForEach(rows, id: \.url) { row in
                    Link(destination: row.url) {
                        Text("\(row.title) · \(row.status.isEmpty ? row.machine : row.status)")
                            .font(.caption).lineLimit(1)
                    }
                }
            }
        } else if family == .accessoryInline {
            Text("Bergr: \(AgentWidgetContent.inlineText(snapshot))")
        } else if family == .systemSmall {
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
            let agents = AgentWidgetContent.mediumAgents(snapshot)
            if agents.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Agents").font(.subheadline.weight(.semibold))
                    Text(snapshot.working > 0 ? "\(snapshot.working) working" : "Nothing needs you")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agents, id: \.url) { agent in
                        Link(destination: agent.url) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: Self.symbol(agent.state)).foregroundStyle(Self.tint(agent.state))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 4) {
                                        Text(agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                                        Text(AgentWidgetContent.stateWord(agent.state))
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if !agent.lastLine.isEmpty {
                                        Text(agent.lastLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private static func symbol(_ state: String) -> String {
        switch state {
        case "needsYou": "exclamationmark.bubble.fill"
        case "working": "circle.dotted"
        default: "checkmark.circle.fill"
        }
    }

    private static func tint(_ state: String) -> Color {
        switch state {
        case "needsYou": .needsYou
        case "working": .working
        default: .done
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
            Text("\(n)").font(.callout.bold().monospacedDigit()).contentTransition(.numericText())
            Text(word).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
