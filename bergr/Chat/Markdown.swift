import SwiftUI

/// The block structure of an agent's markdown reply: enough for prose, lists, code and tables.
enum MarkdownBlock: Hashable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case code(String)
    case table([[String]])
    case quote(String)
    case rule

    var isHeading: Bool { if case .heading = self { true } else { false } }

    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }

        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [cells(trimmed)]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|") {
                    lines.removeFirst()
                    let row = cells(next)
                    // The |---|:--:| line under the header.
                    if row.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && $0.contains("-") }) { continue }
                    rows.append(row)
                }
                blocks.append(.table(rows))
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("!["), trimmed.hasSuffix(")"), trimmed.contains("](") {
                // An image on its own line: the chat shows the image itself below the message.
                flush()
            } else if let level = heading(trimmed) {
                flush()
                blocks.append(.heading(level: level, text: String(trimmed.dropFirst(level + 1))))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let (marker, text) = listItem(trimmed) {
                flush()
                let indent = line.prefix { $0 == " " }.count / 2
                blocks.append(.bullet(indent: min(indent, 4), marker: marker, text: text))
            } else if case .bullet(let indent, let marker, let text)? = blocks.last, paragraph.isEmpty,
                      line.hasPrefix("  ") {
                // A list item's continuation line.
                blocks[blocks.count - 1] = .bullet(indent: indent, marker: marker, text: text + " " + trimmed)
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        return blocks
    }

    private static func cells(_ row: String) -> [String] {
        var s = Substring(row)
        if s.hasPrefix("|") { s = s.dropFirst() }
        if s.hasSuffix("|") { s = s.dropLast() }
        return s.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func heading(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    private static func listItem(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ ", "• "] where line.hasPrefix(bullet) {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 4 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
                return ("\(digits).", String(rest.dropFirst(2)))
            }
        }
        return nil
    }
}

/// The chat's colors.
struct ChatPalette {
    let background, text, secondary, codeText, codeBackground, bubble, field, border: Color
    /// Bergr's gold, from the app icon: the logo's own gold in dark mode, a deeper one in light
    /// mode so text and thin strokes stay readable on the cream background.
    var accent: Color { Color("AccentColor") }
    /// Text and icons on an accent fill: the icon's dark navy on the bright gold, white on the deeper one.
    var onAccent: Color { Color("OnAccentColor") }

    static func of(_ scheme: ColorScheme) -> ChatPalette {
        scheme == .dark
            ? ChatPalette(
                background: Color(white: 0.08), text: Color(white: 0.94), secondary: Color(white: 0.6),
                codeText: Color(red: 0.55, green: 0.69, blue: 0.98), codeBackground: Color(red: 0.15, green: 0.17, blue: 0.21),
                bubble: Color(white: 0.18), field: Color(white: 0.15), border: Color(white: 0.22))
            : ChatPalette(
                background: Color(red: 0.98, green: 0.976, blue: 0.96), text: Color(white: 0.1), secondary: Color(white: 0.45),
                codeText: Color(red: 0.13, green: 0.33, blue: 0.75), codeBackground: Color(red: 0.91, green: 0.92, blue: 0.95),
                bubble: Color(red: 0.92, green: 0.91, blue: 0.88), field: .white, border: Color(white: 0.85))
    }
}

/// Parsed blocks, kept: the chat redraws often (scrolling, the working row), and parsing every
/// message's Markdown each time made a long conversation scroll slowly, on the Mac most of all.
private final class InlineCache: @unchecked Sendable {
    static let shared = InlineCache()
    private let cache: NSCache<NSString, Box> = { let c = NSCache<NSString, Box>(); c.countLimit = 4000; return c }()
    final class Box { let value: AttributedString; init(_ v: AttributedString) { value = v } }
    func value(_ key: String, make: () -> AttributedString) -> AttributedString {
        if let hit = cache.object(forKey: key as NSString) { return hit.value }
        let made = make()
        cache.setObject(Box(made), forKey: key as NSString)
        return made
    }
}

/// Bold, italics, links and `code` within one block.
func inlineMarkdown(_ text: String, palette: ChatPalette) -> AttributedString {
    // The palette only differs between light and dark: its code color tells them apart.
    InlineCache.shared.value("\(palette.codeText.description)\u{1}\(text)") { parseInline(text, palette: palette) }
}

private func parseInline(_ text: String, palette: ChatPalette) -> AttributedString {
    let parsed = (try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    var result = AttributedString()
    for run in parsed.runs {
        var piece = AttributedString(parsed[run.range])
        if run.inlinePresentationIntent?.contains(.code) == true {
            // A short code span stays on one line: its spaces don't break.
            let chars = String(piece.characters)
            if chars.count <= 40, chars.contains(" ") || chars.contains("-") {
                // No-break space and no-break hyphen.
                var unbroken = AttributedString(chars.replacingOccurrences(of: " ", with: "\u{00A0}")
                    .replacingOccurrences(of: "-", with: "\u{2011}"))
                unbroken.mergeAttributes(run.attributes)
                piece = unbroken
            }
            piece.font = .system(.callout, design: .monospaced)
            piece.foregroundColor = palette.codeText
            piece.backgroundColor = palette.codeBackground
        }
        result.append(piece)
    }
    return result
}

/// When a reply that just arrived shows its words: the whole text is laid out from the start (so
/// the list never changes height) and the words not yet revealed are transparent.
enum RevealSchedule {
    /// Words per second for a short reply; a long one speeds up to finish within `maxDuration`.
    static let wordsPerSecond = 45.0
    static let maxDuration = 1.5

    static func duration(totalWords: Int) -> Double {
        min(maxDuration, Double(totalWords) / wordsPerSecond)
    }

    /// How many words show `elapsed` seconds after the reply arrived.
    static func revealedWords(elapsed: Double, totalWords: Int, reduceMotion: Bool) -> Int {
        if reduceMotion || totalWords <= 0 { return totalWords }
        let duration = duration(totalWords: totalWords)
        if elapsed >= duration { return totalWords }
        return max(0, min(totalWords, Int(elapsed / duration * Double(totalWords)) + 1))
    }
}

extension MarkdownBlock {
    /// The text the block shows, for counting and revealing words (tables and rules reveal as one).
    fileprivate var revealText: String? {
        switch self {
        case .paragraph(let t), .quote(let t), .code(let t): t
        case .heading(_, let t): t
        case .bullet(_, _, let t): t
        case .table, .rule: nil
        }
    }

    /// Words in the block as rendered (markdown marks removed); a table or rule counts as one.
    var wordCount: Int {
        guard let text = revealText else { return 1 }
        if case .code = self { return text.split(whereSeparator: \.isWhitespace).count }
        return String(AttributedString.markdownPlain(text).characters).split(whereSeparator: \.isWhitespace).count
    }
}

extension AttributedString {
    fileprivate static func markdownPlain(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// The same text with every word after the first `words` made transparent.
    func revealing(words: Int) -> AttributedString {
        var seen = 0
        var inWord = false
        var cut: AttributedString.Index?
        for i in characters.indices {
            if characters[i].isWhitespace { inWord = false; continue }
            if !inWord {
                inWord = true
                seen += 1
                if seen > words { cut = i; break }
            }
        }
        guard let cut else { return self }
        var result = self
        result[cut...].foregroundColor = .clear
        result[cut...].backgroundColor = .clear
        return result
    }
}

extension MarkdownBlock {
    static func totalWords(_ blocks: [MarkdownBlock]) -> Int { blocks.reduce(0) { $0 + $1.wordCount } }
}

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let palette: ChatPalette
    /// Words shown so far while a reply is revealing; nil shows everything.
    var revealed: Int?

    var body: some View {
        let starts = blocks.reduce(into: [0]) { $0.append($0.last! + $1.wordCount) }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                view(for: block, visibleWords: revealed.map { $0 - starts[i] })
                    // A heading belongs to what follows it: more room above than below.
                    .padding(.top, i > 0 && block.isHeading ? 10 : 0)
            }
        }
        .foregroundStyle(palette.text)
        // No .textSelection: on the Mac it made every scroll-wheel event hit-test the outline of
        // every message's text (a third of the time spent scrolling). Copy and Select Text are in the long-press menu.
    }

    /// Inline text with the not yet revealed words transparent.
    private func text(_ source: String, _ visible: Int?) -> Text {
        let text = inlineMarkdown(source, palette: palette)
        return Text(visible.map { text.revealing(words: max(0, $0)) } ?? text)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock, visibleWords visible: Int?) -> some View {
        switch block {
        case .paragraph(let text):
            self.text(text, visible)
                .lineSpacing(3)
        case .heading(let level, let text):
            self.text(text, visible)
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .accessibilityAddTraits(.isHeader)
        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(palette.secondary).monospacedDigit()
                    .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
                self.text(text, visible).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(visible.map { AttributedString(code).revealing(words: max(0, $0)) } ?? AttributedString(code))
                    .font(.system(.footnote, design: .monospaced))
                    .lineSpacing(2)
                    .padding(14)
            }
            .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        case .table(let rows):
            TableView(rows: rows, palette: palette)
                .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        case .quote(let text):
            self.text(text, visible)
                .foregroundStyle(palette.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 3) }
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
                .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        }
    }
}

private struct TableView: View {
    let rows: [[String]]
    let palette: ChatPalette

    /// Each column as wide as its longest cell needs, between 64 and 240 points (about 7.5 pt a character).
    static func widths(_ rows: [[String]], columns: Int) -> [CGFloat] {
        (0..<columns).map { c in
            let longest = rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
            return min(240, max(64, CGFloat(longest) * 7.5))
        }
    }

    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        let widths = Self.widths(rows, columns: columns)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(rows.indices, id: \.self) { r in
                    GridRow(alignment: .top) {
                        ForEach(0..<columns, id: \.self) { c in
                            Text(inlineMarkdown(c < rows[r].count ? rows[r][c] : "", palette: palette))
                                .font(r == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                // A set width per column: with a flexible one, Grid sized rows for
                                // unwrapped text, and wrapped lines drew over the next row.
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: widths[c], alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    if r < rows.count - 1 {
                        Rectangle().fill(palette.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.border))
            .padding(1)
        }
        // A wide table scrolls to the screen's edge, and rests inside the text margins.
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .padding(.horizontal, -16)
    }
}
