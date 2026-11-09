import HerdrKit
import SwiftUI

/// One agent (or plain shell) terminal in the all-machines list.
struct AgentRow: View {
    let terminal: Terminal
    /// Sub-agents its agent is running now (known while its chat is being followed).
    var subagents = 0
    /// The machine it runs on, shown when the list isn't grouped by machine.
    var machine: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    /// At the largest text sizes a title wraps instead of being cut to a few letters.
    private var lines: Int { typeSize.isAccessibilitySize ? 3 : 1 }

    private var kind: AgentKind { AgentKind.of(terminal) }
    private var state: AgentState? { terminal.agentState }
    /// Plain shells and finished terminals step back; every agent, idle ones too, reads at full strength.
    private var dimmed: Bool { !terminal.isLive || state == nil }

    var body: some View {
        HStack(spacing: 10) {
            AgentLogo(kind: kind, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                // What needs you reads first: weight, not color, carries the urgency.
                Text(AgentsOrdering.title(terminal))
                    .fontWeight(state == .needsYou ? .semibold : .regular)
                    .lineLimit(lines)
                if machine != nil || AgentsOrdering.info(terminal) != nil {
                    HStack(spacing: 6) {
                        if let machine {
                            Text(machine)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        if let info = AgentsOrdering.info(terminal) {
                            Text(info).font(.footnote).foregroundStyle(.secondary).lineLimit(lines)
                        }
                    }
                }
                if subagents > 0 {
                    Label("\(subagents) sub-agent\(subagents == 1 ? "" : "s") running", systemImage: "person.2.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let since = terminal.statusSince {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let age = Terminal.shortAge(since, now: context.date)
                    Text(age == "now" ? "<1m" : age)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            if let state {
                // A new state arrives in place: the old mark gives way to the new one.
                StatusMark(state: state)
                    .id(state)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(minHeight: 44)
        .opacity(dimmed ? 0.6 : 1)
        .animation(.smooth(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(terminal.address)
    }
}

/// Spinning ring = working, green dot = done (unread), hollow ring = idle, hand = blocked.
struct StatusMark: View {
    let state: AgentState
    @State private var spinning = false

    var body: some View {
        Group {
            switch state {
            case .working:
                Circle().trim(from: 0.12, to: 1)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spinning)
                    .onAppear { spinning = true }
            case .done:
                Circle().fill(Color.green).frame(width: 10, height: 10)
            case .idle:
                Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 10, height: 10)
            case .needsYou:
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.needsYou)
            case .error:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(state.title)
    }
}
