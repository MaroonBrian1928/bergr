import SwiftUI

/// A read-only preview when Claude doesn't write a transcript. Keep terminal
/// output separate from saved messages so it never enters the conversation feed.
struct ClaudeTerminalHistory: View {
    let model: TerminalScreenModel
    let palette: ChatPalette
    @State private var preview = ""
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recent terminal output", systemImage: "terminal")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.text)
            Text("Claude isn’t saving a transcript. Terminal output can contain sensitive information.")
                .font(.caption)
                .foregroundStyle(palette.secondary)
            DisclosureGroup("Show terminal output", isExpanded: $expanded) {
                Text(verbatim: preview)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(palette.bubble, in: RoundedRectangle(cornerRadius: 14))
        .task(id: expanded) {
            guard expanded else { preview = ""; return }
            var lastScreen: [String]?
            while !Task.isCancelled {
                let screen = model.textLines
                if screen != lastScreen {
                    preview = model.recentTerminalText().joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    lastScreen = screen
                }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            }
        }
    }
}
