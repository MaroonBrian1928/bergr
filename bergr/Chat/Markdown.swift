import SwiftUI

/// Inline Markdown, parsed once when its block is parsed. Both palettes' colors are applied then,
/// so drawing a block applies no attributes and parses nothing.
struct MarkdownInline: Hashable, ExpressibleByStringLiteral {
    let source: String
    /// Words as rendered (markdown marks removed).
    let words: Int
    private let light: AttributedString
    private let dark: AttributedString

    init(_ source: String) {
        self.source = source
        let plain = Self.markup(source)
        words = Self.plainWords(plain)
        light = Self.styled(plain, palette: .of(.light))
        dark = Self.styled(plain, palette: .of(.dark))
    }

    init(stringLiteral value: String) { self.init(value) }

    /// The text in the palette's colors, ready to draw.
    func styled(_ palette: ChatPalette) -> AttributedString { palette.isDark ? dark : light }

    static func == (a: MarkdownInline, b: MarkdownInline) -> Bool { a.source == b.source }
    func hash(into hasher: inout Hasher) { hasher.combine(source) }

    /// Words in Markdown source, as rendered: the count `init` stores, worked out from scratch.
    static func wordsUncached(_ source: String) -> Int { plainWords(markup(source)) }

    private static func markup(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static func plainWords(_ plain: AttributedString) -> Int {
        String(plain.characters).split(whereSeparator: \.isWhitespace).count
    }

    /// Bold, italics and links from the markup; `code` gets the palette's code colors.
    private static func styled(_ parsed: AttributedString, palette: ChatPalette) -> AttributedString {
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
}

/// A fenced code block, with its text ready to draw and its words counted.
struct MarkdownCode: Hashable, ExpressibleByStringLiteral {
    let text: String
    let words: Int
    let attributed: AttributedString

    init(_ text: String) {
        self.text = text
        words = text.split(whereSeparator: \.isWhitespace).count
        attributed = AttributedString(text)
    }

    init(stringLiteral value: String) { self.init(value) }

    static func == (a: MarkdownCode, b: MarkdownCode) -> Bool { a.text == b.text }
    func hash(into hasher: inout Hasher) { hasher.combine(text) }
}

/// A table with its column widths and cell text worked out once: a row redraw reads them.
struct MarkdownTable: Hashable, ExpressibleByArrayLiteral {
    let rows: [[String]]
    let columns: Int
    /// Each column as wide as its longest cell needs, between 64 and 240 points (about 7.5 pt a character).
    let widths: [CGFloat]
    /// Every row's cells, padded to `columns`, with their text ready to draw.
    let cells: [[MarkdownInline]]

    init(_ rows: [[String]]) {
        self.rows = rows
        let columns = rows.map(\.count).max() ?? 0
        self.columns = columns
        widths = (0..<columns).map { c in
            let longest = rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
            return min(240, max(64, CGFloat(longest) * 7.5))
        }
        cells = rows.map { row in
            (0..<columns).map { c in MarkdownInline(c < row.count ? row[c] : "") }
        }
    }

    init(arrayLiteral rows: [String]...) { self.init(rows) }

    static func == (a: MarkdownTable, b: MarkdownTable) -> Bool { a.rows == b.rows }
    func hash(into hasher: inout Hasher) { hasher.combine(rows) }
}

/// One block of an agent's markdown reply: enough for prose, lists, code and tables. The payloads
/// are parsed when the block is made, so drawing one does no parsing.
///
/// A class, so a block that stays the same while its message streams keeps one identity: the views
/// built from it compare as a reference and skip their body (see `MarkdownBlockView`).
final class MarkdownBlock: Hashable, @unchecked Sendable {
    enum Kind: Hashable {
        case paragraph(MarkdownInline)
        case heading(level: Int, text: MarkdownInline)
        case bullet(indent: Int, marker: String, text: MarkdownInline)
        case code(MarkdownCode)
        case table(MarkdownTable)
        case quote(MarkdownInline)
        case rule
    }

    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    static func paragraph(_ text: String) -> MarkdownBlock { MarkdownBlock(.paragraph(MarkdownInline(text))) }
    static func heading(level: Int, text: String) -> MarkdownBlock {
        MarkdownBlock(.heading(level: level, text: MarkdownInline(text)))
    }
    static func bullet(indent: Int, marker: String, text: String) -> MarkdownBlock {
        MarkdownBlock(.bullet(indent: indent, marker: marker, text: MarkdownInline(text)))
    }
    static func code(_ text: String) -> MarkdownBlock { MarkdownBlock(.code(MarkdownCode(text))) }
    static func table(_ rows: [[String]]) -> MarkdownBlock { MarkdownBlock(.table(MarkdownTable(rows))) }
    static func quote(_ text: String) -> MarkdownBlock { MarkdownBlock(.quote(MarkdownInline(text))) }
    static let rule = MarkdownBlock(.rule)

    var isHeading: Bool { if case .heading = kind { true } else { false } }

    static func == (a: MarkdownBlock, b: MarkdownBlock) -> Bool { a === b || a.kind == b.kind }
    func hash(into hasher: inout Hasher) { hasher.combine(kind) }

    /// `new` with each block that equals the one at its place in `old` replaced by that very
    /// object: a streaming message keeps the identity of its finished blocks.
    static func reusing(_ old: [MarkdownBlock], in new: [MarkdownBlock]) -> [MarkdownBlock] {
        var result = new
        for i in 0..<min(old.count, new.count) where old[i] == new[i] { result[i] = old[i] }
        return result
    }

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
            } else if case .bullet(let indent, let marker, let text)? = blocks.last?.kind, paragraph.isEmpty,
                      line.hasPrefix("  ") {
                // A list item's continuation line.
                blocks[blocks.count - 1] = .bullet(
                    indent: indent, marker: marker, text: text.source + " " + trimmed)
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

    /// Words in the block as rendered (markdown marks removed); a table or rule counts as one.
    /// Read from the counts stored when the block was parsed.
    var wordCount: Int {
        switch kind {
        case .paragraph(let t), .quote(let t), .heading(_, let t), .bullet(_, _, let t): t.words
        case .code(let c): c.words
        case .table, .rule: 1
        }
    }

    /// The count worked out again from the source, to check the stored one.
    var wordCountUncached: Int {
        switch kind {
        case .paragraph(let t), .quote(let t), .heading(_, let t), .bullet(_, _, let t):
            MarkdownInline.wordsUncached(t.source)
        case .code(let c): c.text.split(whereSeparator: \.isWhitespace).count
        case .table, .rule: 1
        }
    }

    static func totalWords(_ blocks: [MarkdownBlock]) -> Int { blocks.reduce(0) { $0 + $1.wordCount } }
}

/// The chat's colors.
struct ChatPalette {
    let background, text, secondary, codeText, codeBackground, bubble, field, border: Color
    let isDark: Bool
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
                bubble: Color(white: 0.18), field: Color(white: 0.15), border: Color(white: 0.22), isDark: true)
            : ChatPalette(
                background: Color(red: 0.98, green: 0.976, blue: 0.96), text: Color(white: 0.1), secondary: Color(white: 0.45),
                codeText: Color(red: 0.13, green: 0.33, blue: 0.75), codeBackground: Color(red: 0.91, green: 0.92, blue: 0.95),
                bubble: Color(red: 0.92, green: 0.91, blue: 0.88), field: .white, border: Color(white: 0.85), isDark: false)
    }
}

extension AttributedString {
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

struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    let palette: ChatPalette
    /// Words shown so far while a reply is revealing; nil shows everything.
    let revealed: Int?
    /// Where each block's words start, counted once with the blocks (empty when nothing is revealing).
    private let starts: [Int]

    init(blocks: [MarkdownBlock], palette: ChatPalette, revealed: Int? = nil) {
        self.blocks = blocks
        self.palette = palette
        self.revealed = revealed
        var starts: [Int] = []
        if revealed != nil {
            starts.reserveCapacity(blocks.count + 1)
            starts.append(0)
            for block in blocks { starts.append(starts[starts.count - 1] + block.wordCount) }
        }
        self.starts = starts
    }

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.hit("MarkdownView")
        #endif
        let dark = palette.isDark
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                MarkdownBlockView(block: block, dark: dark, visible: visible(i, block))
                    // A heading belongs to what follows it: more room above than below.
                    .padding(.top, i > 0 && block.isHeading ? 10 : 0)
            }
        }
        .foregroundStyle(palette.text)
        // No .textSelection: on the Mac it made every scroll-wheel event hit-test the outline of
        // every message's text (a third of the time spent scrolling). Copy and Select Text are in the long-press menu.
    }

    /// The words of block `i` to show: -1 for all of them (so a finished block's value stays the
    /// same while a reply reveals), 0 for none, else the count.
    private func visible(_ i: Int, _ block: MarkdownBlock) -> Int {
        guard let revealed else { return -1 }
        let words = revealed - starts[i]
        return words >= block.wordCount ? -1 : max(0, words)
    }
}

/// One block. Its three fields are plain words (a reference, a flag, a number), the same bit for
/// bit while the block is unchanged, so SwiftUI skips it at once: a streamed token builds and
/// measures only the block that grew (see `RowSlot` for why it isn't `Equatable`).
private struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let dark: Bool
    /// Words shown; -1 shows everything.
    let visible: Int

    private static let codeFont = Font.system(.footnote, design: .monospaced)

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.hit("MarkdownBlockView")
        #endif
        let palette = ChatPalette.of(dark ? .dark : .light)
        let visible: Int? = visible >= 0 ? visible : nil
        switch block.kind {
        case .paragraph(let inline):
            inlineText(inline, visible, palette)
                .lineSpacing(3)
        case .heading(let level, let inline):
            inlineText(inline, visible, palette)
                .font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .accessibilityAddTraits(.isHeader)
        case .bullet(let indent, let marker, let inline):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(palette.secondary).monospacedDigit()
                    .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
                inlineText(inline, visible, palette).lineSpacing(3)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .code(let code):
            // Wrapped, not scrolled: a nested horizontal ScrollView per code block was costly to lay out and scroll.
            Text(visible.map { code.attributed.revealing(words: max(0, $0)) } ?? code.attributed)
                .font(Self.codeFont)
                .lineSpacing(2)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        case .table(let table):
            MarkdownTableView(table: table, palette: palette)
                .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        case .quote(let inline):
            inlineText(inline, visible, palette)
                .foregroundStyle(palette.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(palette.border).frame(width: 3) }
        case .rule:
            Rectangle().fill(palette.border).frame(height: 1)
                .opacity(visible.map { $0 > 0 } ?? true ? 1 : 0)
        }
    }

    /// Inline text with the not yet revealed words transparent.
    private func inlineText(_ inline: MarkdownInline, _ visible: Int?, _ palette: ChatPalette) -> Text {
        let styled = inline.styled(palette)
        return Text(visible.map { styled.revealing(words: max(0, $0)) } ?? styled)
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let palette: ChatPalette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(table.cells.indices, id: \.self) { r in
                    GridRow(alignment: .top) {
                        ForEach(0..<table.columns, id: \.self) { c in
                            Text(table.cells[r][c].styled(palette))
                                .font(r == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                // A set width per column: with a flexible one, Grid sized rows for
                                // unwrapped text, and wrapped lines drew over the next row.
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: table.widths[c], alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    if r < table.cells.count - 1 {
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

#if DEBUG
/// Counts body evaluations by view name, so tests can tell what an update rebuilt.
@MainActor
enum RenderProbe {
    static var counts: [String: Int] = [:]
    static func hit(_ name: String) { counts[name, default: 0] += 1 }
}
#endif
