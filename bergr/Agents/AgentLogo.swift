import HerdrKit
import SwiftUI

/// Which program a terminal runs, for its logo.
enum AgentKind {
    case claude, codex, antigravity, shell

    static func of(_ terminal: Terminal) -> AgentKind {
        switch ChatAgent.detect(terminal) {
        case .claude: .claude
        case .codex: .codex
        case .antigravity: .antigravity
        case nil: .shell
        }
    }
}

/// Our own simple marks, recognisable by color: rounded squares with a white symbol.
struct AgentLogo: View {
    let kind: AgentKind
    var size: CGFloat = 20

    init(kind: AgentKind, size: CGFloat = 20) {
        self.kind = kind
        self.size = size
    }

    var body: some View {
        // The agents' own marks (the same icons herdr shows); a shell is drawn in the text color.
        Image(asset)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var asset: String {
        switch kind {
        case .claude: "AgentClaude"
        case .codex: "AgentCodex"
        case .antigravity: "AgentAntigravity"
        case .shell: "AgentShell"
        }
    }

    private var symbol: String {
        switch kind {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .antigravity: "triangle.fill"
        case .shell: "apple.terminal"
        }
    }

    private var fill: AnyShapeStyle {
        switch kind {
        case .claude: AnyShapeStyle(Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
        case .codex: AnyShapeStyle(Color(red: 0x2B / 255, green: 0x2F / 255, blue: 0x7E / 255))
        case .antigravity:
            AnyShapeStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .shell: AnyShapeStyle(Color.gray)
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        AgentLogo(kind: .claude)
        AgentLogo(kind: .codex)
        AgentLogo(kind: .antigravity)
        AgentLogo(kind: .shell)
    }
    .padding()
}
