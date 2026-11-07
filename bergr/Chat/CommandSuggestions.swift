import SwiftUI

/// Picks the commands (`/…`) or skills (`$…`) that a reply draft could be starting with.
enum CommandMatcher {
    /// Matches while `draft` starts with "/" or "$" and has no whitespace yet: names starting with the
    /// draft first (case-insensitive), then names containing the rest of it, at most `limit`.
    /// Empty when the draft is not a command prefix, or when it already equals the only match.
    static func matches(_ commands: [ChatFeed.Command], draft: String, limit: Int = 6) -> [ChatFeed.Command] {
        guard let sigil = draft.first, sigil == "/" || sigil == "$",
              !draft.contains(where: \.isWhitespace) else { return [] }
        let query = draft.lowercased()
        let rest = String(query.dropFirst())
        var starts: [ChatFeed.Command] = []
        var contains: [ChatFeed.Command] = []
        for command in commands where command.name.first == sigil {
            let name = command.name.lowercased()
            if name.hasPrefix(query) {
                starts.append(command)
            } else if name.dropFirst().contains(rest) {
                contains.append(command)
            }
        }
        let found = Array((starts + contains).prefix(limit))
        if found.count == 1, found[0].name.lowercased() == query { return [] }
        return found
    }
}

/// A card of matching commands above the reply bar. Tapping one fills the draft in.
struct CommandSuggestions: View {
    let commands: [ChatFeed.Command]
    let draft: Binding<String>
    let palette: ChatPalette

    @State private var picks = 0

    var body: some View {
        let found = CommandMatcher.matches(commands, draft: draft.wrappedValue)
        if found.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(found.enumerated()), id: \.element.id) { index, command in
                    if index > 0 {
                        Divider().padding(.leading, 16)
                    }
                    row(command)
                }
            }
            .padding(.vertical, 4)
            .foregroundStyle(palette.text)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .sensoryFeedback(.selection, trigger: picks)
        }
    }

    private func row(_ command: ChatFeed.Command) -> some View {
        Button {
            draft.wrappedValue = command.name + " "
            picks += 1
        } label: {
            HStack(spacing: 10) {
                Text(highlighted(command.name))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(command.description)
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The name with the typed part (after its sigil) in semibold.
    private func highlighted(_ name: String) -> AttributedString {
        var text = AttributedString(name)
        let typed = String(draft.wrappedValue.dropFirst())
        if !typed.isEmpty, let range = text.range(of: typed, options: .caseInsensitive) {
            text[range].font = Font.callout.monospaced().weight(.semibold)
        }
        return text
    }
}
