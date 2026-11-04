import Foundation

/// Finds URLs written as plain text in a line of cells.
public enum LinkDetector {
    public struct Link: Hashable, Sendable {
        /// Cell columns the link covers (inclusive).
        public var columns: ClosedRange<Int>
        public var url: URL
    }

    // Explicit schemes only: bare words like "README.md" must not become links.
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?|ssh|ftp|file)://[^\s<>"'`]+"#, options: [.caseInsensitive])

    public static func links(in line: [ScreenCell]) -> [Link] {
        // Text with one character per cell, plus where each UTF-16 offset came from.
        var text = ""
        var columnAt: [Int] = []
        for (column, cell) in line.enumerated() where cell.width != 0 {
            let piece = cell.text.isEmpty ? " " : cell.text
            text += piece
            columnAt += Array(repeating: column, count: piece.utf16.count)
        }
        guard text.contains("://") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let raw = trimmed(String(text[swiftRange]))
            guard let url = URL(string: raw), !raw.isEmpty else { return nil }
            let start = match.range.location
            let end = start + raw.utf16.count - 1
            guard start < columnAt.count, end < columnAt.count else { return nil }
            return Link(columns: columnAt[start]...columnAt[end], url: url)
        }
    }

    /// Drops sentence punctuation and unbalanced closing brackets after a URL.
    private static func trimmed(_ url: String) -> String {
        var url = url
        while let last = url.last {
            if ".,;:!?".contains(last) {
                url.removeLast()
            } else if let open = ["(": ")", "[": "]", "{": "}"].first(where: { $0.value == String(last) })?.key,
                      url.filter({ String($0) == String(last) }).count > url.filter({ String($0) == open }).count
            {
                url.removeLast()
            } else {
                break
            }
        }
        return url
    }
}
