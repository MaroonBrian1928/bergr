import Foundation

/// Finding text in a terminal's lines (scrollback plus screen), and the previous/next shell
/// prompt. Pure functions over strings: `VirtualTerminal.textSnapshot()` supplies the lines.
public enum TerminalSearch {
    /// One hit: a row of the scrollback (row 0 is its oldest line) and where in it, in characters.
    public struct Match: Hashable, Sendable {
        public var row: Int
        public var start: Int
        public var length: Int

        public init(row: Int, start: Int, length: Int) {
            self.row = row
            self.start = start
            self.length = length
        }
    }

    /// Every case-insensitive occurrence of `query`, oldest first. Matches stay inside one row
    /// (a line the terminal wrapped can hide one that straddles the wrap). A blank query has none.
    public static func matches(for query: String, in lines: [String]) -> [Match] {
        guard !query.isEmpty else { return [] }
        var found: [Match] = []
        for (row, line) in lines.enumerated() where !line.isEmpty {
            var from = line.startIndex
            while from < line.endIndex,
                  let range = line.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: from..<line.endIndex),
                  !range.isEmpty
            {
                found.append(Match(
                    row: row, start: line.distance(from: line.startIndex, to: range.lowerBound),
                    length: line.distance(from: range.lowerBound, to: range.upperBound)))
                from = range.upperBound
            }
        }
        return found
    }

    /// The match after (or before) `current`, wrapping around at the ends. Without a current
    /// one, forward gives the first and backward the last. Nil when there are no matches.
    public static func step(from current: Int?, count: Int, forward: Bool) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return forward ? 0 : count - 1 }
        return forward ? (current + 1) % count : (current + count - 1) % count
    }

    /// The match to start on: the first at or after `row` (the top of what is on screen), else
    /// the first one overall.
    public static func firstMatch(atOrAfter row: Int, in matches: [Match]) -> Int? {
        guard !matches.isEmpty else { return nil }
        return matches.firstIndex { $0.row >= row } ?? 0
    }

    /// The terminal column a character offset of a row starts at: wide characters take two.
    public static func column(ofCharacter offset: Int, in line: String) -> Int {
        line.prefix(offset).reduce(0) { $0 + width(of: $1) }
    }

    public static func width(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 1 }
        let v = scalar.value
        if scalar.properties.isEmojiPresentation { return 2 }
        switch v {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
             0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

/// Finds the lines where a shell prompt starts.
public enum PromptDetector {
    /// Prompt rows by OSC 133 marks when the shell sends them (exact), else by how the line
    /// looks (a heuristic: see `looksLikePrompt`).
    public static func promptRows(lines: [String], marked: [Int]) -> [Int] {
        if !marked.isEmpty { return marked }
        return lines.indices.filter { looksLikePrompt(lines[$0]) }
    }

    /// Whether a line reads as a prompt: `user@host:~/dir$ `, `~/src/app % `, `dir ❯ `, or a bare
    /// `❯ ` / `➜ `. Plain `> ` is too common in quoted text to count on its own, but after a
    /// path it does.
    public static func looksLikePrompt(_ line: String) -> Bool {
        let line = line.replacingOccurrences(of: "\u{a0}", with: " ")
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    private static let patterns = [
        // user@host:path$ , user@host path % , [user@host path]#
        #"^\[?[\w.-]+@[\w.-]+[: \]].*?[$%#]( |$)"#,
        #"^\[?[\w.-]+@[\w.-]+\]?[$%#]( |$)"#,
        // ~/dir % , /usr/local $ , ~/dir ❯
        #"^[~/]\S*\s*[$%#>❯➜]( |$)"#,
        // a bare glyph prompt (not a menu choice such as "❯ 1. Yes")
        #"^[❯➜λ]( +(?!\d+[.)])|$)"#,
        // starship and friends: "dir ❯ ", "dir git:(main) ➜ "
        #"^\S+(\s+\S+)?\s+[❯➜]( |$)"#,
        // (venv) user@host ...
        #"^\([\w.-]+\)\s+[\w.-]+@[\w.-]+.*?[$%#]( |$)"#,
    ]

    /// The prompt row to scroll to from a viewport whose top is `viewportTop`: the nearest one
    /// above it (forward false) or below it. Nil when there is none that way.
    public static func jump(from viewportTop: Int, rows: [Int], forward: Bool) -> Int? {
        forward ? rows.filter { $0 > viewportTop }.min() : rows.filter { $0 < viewportTop }.max()
    }
}
