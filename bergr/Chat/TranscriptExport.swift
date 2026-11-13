import CoreTransferable
import Foundation

/// The chat as Markdown, for Copy and Share. Pure: the same items give the same text.
enum TranscriptExport {
    /// Your messages and the agent's under "You" and the agent's name, code blocks kept as written,
    /// each run of tool calls as one-line bullets. Plans, answers and images are left out.
    /// An empty chat gives an empty string.
    static func markdown(items: [ChatFeed.Item], agent: String) -> String {
        var sections: [String] = []
        var steps: [String] = []
        func flushSteps() {
            if !steps.isEmpty { sections.append(steps.joined(separator: "\n")); steps = [] }
        }
        for item in items {
            switch item.kind {
            case .tool(let name, let summary):
                steps.append(toolLine(name: name, summary: summary))
            case .user(let text):
                flushSteps()
                if let body = trimmed(text) { sections.append("## You\n\n" + body) }
            case .assistant(let text, _):
                flushSteps()
                if let body = trimmed(text) { sections.append("## \(agent)\n\n" + body) }
            default:
                continue
            }
        }
        flushSteps()
        return sections.isEmpty ? "" : sections.joined(separator: "\n\n") + "\n"
    }

    /// One message as plain text for the share sheet.
    static func plain(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static func toolLine(name: String, summary: String) -> String {
        let one = summary.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let detail = one.trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? "- \(name)" : "- \(name): \(detail)"
    }

    private static func trimmed(_ text: String) -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}

/// A conversation built when it is shared, not each time the menu redraws.
struct TranscriptShare: Transferable {
    let make: @MainActor @Sendable () -> String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { (share: TranscriptShare) async -> String in
            await MainActor.run { share.make() }
        }
    }
}
