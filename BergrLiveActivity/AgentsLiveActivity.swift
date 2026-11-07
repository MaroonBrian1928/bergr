import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

extension Color {
    /// Bergr's amber: a terminal waits for you.
    static let needsYou = Color(red: 0xf2 / 255, green: 0xb3 / 255, blue: 0x3d / 255)
    static let working = Color(red: 0x5a / 255, green: 0xa9 / 255, blue: 0xff / 255)
    static let done = Color(red: 0x4c / 255, green: 0xd1 / 255, blue: 0x7a / 255)
}

typealias AgentState = BergrActivityAttributes.ContentState
typealias AgentRow = BergrActivityAttributes.Row

struct AgentsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BergrActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { LeadingCount(state: context.state) }
                DynamicIslandExpandedRegion(.trailing) { CountsRow(state: context.state) }
                DynamicIslandExpandedRegion(.bottom) {
                    if let prompt = context.state.prompt {
                        PromptView(prompt: prompt, compact: true)
                    } else {
                        RowsList(rows: context.state.rows)
                    }
                }
            } compactLeading: {
                // Who: the most urgent agent's mark. The trailing side says what it's doing.
                if let top = context.state.rows.first { Mark(kind: top.kind).scaleEffect(0.85) }
            } compactTrailing: {
                UrgentCount(state: context.state)
            } minimal: {
                UrgentCount(state: context.state)
            }
            .widgetURL(context.state.rows.first?.url)
        }
    }
}

/// One count, the most urgent: needs-you in amber, else working in blue, else done in green.
private struct UrgentCount: View {
    let state: AgentState
    var body: some View {
        if state.needsYou > 0 {
            Label("\(state.needsYou)", systemImage: "exclamationmark.bubble.fill")
                .labelStyle(CountStyle(tint: .needsYou)).accessibilityLabel("\(state.needsYou) need you")
        } else if state.working > 0 {
            Label("\(state.working)", systemImage: "circle.dotted")
                .labelStyle(CountStyle(tint: .working)).accessibilityLabel("\(state.working) working")
        } else {
            Label("\(state.done)", systemImage: "checkmark.circle.fill")
                .labelStyle(CountStyle(tint: .done)).accessibilityLabel("\(state.done) ready")
        }
    }
}

/// A small mark plus the most urgent count: needs-you in amber, else working.
private struct LeadingCount: View {
    let state: AgentState
    var body: some View {
        if state.needsYou > 0 {
            Label("\(state.needsYou)", systemImage: "exclamationmark.bubble.fill")
                .labelStyle(CountStyle(tint: .needsYou))
                .accessibilityLabel("\(state.needsYou) need you")
        } else {
            Label("\(state.working)", systemImage: "circle.dotted")
                .labelStyle(CountStyle(tint: .working))
                .accessibilityLabel("\(state.working) working")
        }
    }
}

private struct CountStyle: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.caption.weight(.semibold))
            configuration.title.font(.callout.bold().monospacedDigit())
        }
        .foregroundStyle(tint)
    }
}

private struct CountsRow: View {
    let state: AgentState
    var body: some View {
        HStack(spacing: 10) {
            Label("\(state.needsYou)", systemImage: "exclamationmark.bubble.fill").labelStyle(CountStyle(tint: .needsYou))
                .accessibilityLabel("\(state.needsYou) need you")
            Label("\(state.working)", systemImage: "circle.dotted").labelStyle(CountStyle(tint: .working))
                .accessibilityLabel("\(state.working) working")
            Label("\(state.done)", systemImage: "checkmark.circle.fill").labelStyle(CountStyle(tint: .done))
                .accessibilityLabel("\(state.done) done")
        }
    }
}

private struct RowsList: View {
    let rows: [AgentRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.url) { row in
                Link(destination: row.url) { AgentRowView(row: row) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LockScreenView: View {
    let state: AgentState
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents").font(.subheadline.weight(.semibold))
                Spacer()
                CountsRow(state: state)
            }
            if let prompt = state.prompt {
                PromptView(prompt: prompt, compact: false)
            } else {
                RowsList(rows: state.rows)
            }
        }
        .padding(14)
        .foregroundStyle(.white)
    }
}

private struct AgentRowView: View {
    let row: AgentRow
    var body: some View {
        HStack(spacing: 8) {
            Mark(kind: row.kind)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(row.status.isEmpty ? row.machine : "\(row.status) · \(row.machine)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if row.needsYou {
                Circle().fill(Color.needsYou).frame(width: 8, height: 8)
            }
        }
    }
}

/// The agent's own logo, the same one the app and herdr show; a shell is drawn in white.
private struct Mark: View {
    let kind: String
    var body: some View {
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: 20, height: 20)
            .foregroundStyle(.white)
            .accessibilityHidden(true)
    }
    private var asset: String {
        switch kind {
        case "claude": "AgentClaude"
        case "codex": "AgentCodex"
        case "antigravity": "AgentAntigravity"
        default: "AgentShell"
        }
    }
}

/// The most urgent blocked agent's question with its answers as buttons. Each button runs an
/// intent in the app, which answers only if the question is still the one on screen.
private struct PromptView: View {
    let prompt: BergrActivityAttributes.Prompt
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            Label {
                Text(prompt.question).lineLimit(compact ? 2 : 3)
            } icon: {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.needsYou)
            }
            .font(compact ? .footnote.weight(.semibold) : .subheadline.weight(.semibold))
            Text(prompt.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                Button(intent: AnswerPromptIntent(
                    host: prompt.host, address: prompt.address, question: prompt.question, option: option)
                ) {
                    HStack(spacing: 8) {
                        if option.number > 0 {
                            Text("\(option.number)").font(.caption.monospacedDigit().weight(.bold)).opacity(0.7)
                        } else {
                            Image(systemName: symbol(option)).font(.caption.weight(.bold))
                        }
                        Text(option.label).font(compact ? .footnote : .subheadline).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: compact ? 28 : 32, alignment: .leading)
                    .foregroundStyle(index == 0 ? Color(red: 0x30 / 255, green: 0x34 / 255, blue: 0x38 / 255) : .white)
                    .background(index == 0 ? Color.needsYou : Color.white.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Link(destination: URL(string: "bergr://terminal?host=\(prompt.host)&address=\(prompt.address)")
                ?? URL(string: "bergr://terminal")!) {
                Label("Open", systemImage: "arrow.up.forward.app").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func symbol(_ option: BergrActivityAttributes.Option) -> String {
        switch option.key {
        case "y": "checkmark"
        case "n": "xmark"
        default: "escape"
        }
    }
}
