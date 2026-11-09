import SwiftUI

/// Picks the commands (`/…`) or skills (`$…`) that a reply draft could be starting with.
enum CommandMatcher {
    /// The word being typed at the end of the draft when it's a command ("/…" or "$…"), anywhere
    /// in the message: at the start or after a space, not yet followed by one.
    static func token(in draft: String) -> Range<String.Index>? {
        guard let last = draft.last, !last.isWhitespace else { return nil }
        let start = draft.lastIndex(where: \.isWhitespace).map { draft.index(after: $0) } ?? draft.startIndex
        guard draft[start] == "/" || draft[start] == "$" else { return nil }
        return start..<draft.endIndex
    }

    /// The draft with the command being typed replaced by `name` and a space.
    static func picking(_ name: String, in draft: String) -> String {
        guard let range = token(in: draft) else { return name + " " }
        return draft.replacingCharacters(in: range, with: name + " ")
    }

    /// Matches while the word being typed starts with "/" or "$" (see `token`): names starting
    /// with it first (case-insensitive), then names containing the rest of it, at most `limit`.
    /// Empty when no command is being typed, or when it already equals the only match.
    static func matches(_ commands: [ChatFeed.Command], draft: String, limit: Int = 6) -> [ChatFeed.Command] {
        guard let range = token(in: draft) else { return [] }
        let typed = draft[range]
        let sigil = typed.first!
        let query = typed.lowercased()
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
        // Every match, not just the first few: the card shows about five rows and scrolls.
        let found = CommandMatcher.matches(commands, draft: draft.wrappedValue, limit: 400)
        if found.isEmpty {
            EmptyView()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, command in
                        if index > 0 {
                            Divider().padding(.leading, 16)
                        }
                        row(command)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: min(CGFloat(found.count) * 44 + 8, 5.5 * 44 + 8))
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.visible)
            .foregroundStyle(palette.text)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .sensoryFeedback(.selection, trigger: picks)
        }
    }

    private func row(_ command: ChatFeed.Command) -> some View {
        Button {
            draft.wrappedValue = CommandMatcher.picking(command.name, in: draft.wrappedValue)
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
        let typed = CommandMatcher.token(in: draft.wrappedValue).map { String(draft.wrappedValue[$0].dropFirst()) } ?? ""
        if !typed.isEmpty, let range = text.range(of: typed, options: .caseInsensitive) {
            text[range].font = Font.callout.monospaced().weight(.semibold)
        }
        return text
    }
}
