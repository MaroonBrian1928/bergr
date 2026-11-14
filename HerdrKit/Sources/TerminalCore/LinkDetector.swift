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
    static func trimmed(_ url: String) -> String {
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

/// A web page on the agent's machine (`http://localhost:3000/path`). The app previews it through
/// the SSH connection instead of opening the browser, where localhost is the wrong machine.
public struct LocalWebAddress: Hashable, Sendable {
    public var scheme: String
    public var port: Int
    /// Path, query and fragment, percent-encoded, starting with "/" (or empty).
    public var path: String

    private static let hosts: Set<String> = ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]

    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false)?.lowercased(), Self.hosts.contains(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.port = port
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        if let fragment = components.percentEncodedFragment { path += "#" + fragment }
        self.path = path
    }

    /// As the agent would write it: `localhost:3000/path`.
    public var display: String { "localhost:\(port)\(path == "/" ? "" : path)" }

    /// The original address, on localhost.
    public var url: URL { URL(string: "\(scheme)://localhost:\(port)\(path)")! }

    /// The same page through a forward to `localPort` on this device.
    public func forwarded(to localPort: Int) -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(localPort)\(path)")!
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:https?://)?(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d{1,5}(?:[/?#][^\s<>"'`]*)?"#,
        options: [.caseInsensitive])

    /// Local addresses written in plain text, with or without `http://` (a port is required).
    public static func matches(in text: String) -> [(range: Range<String.Index>, address: LocalWebAddress)] {
        guard text.contains(":") else { return [] }
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            // "user@localhost:22", "app.localhost:3000" and "xlocalhost:1" are not local web addresses.
            if range.lowerBound > text.startIndex {
                let before = text[text.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber || "@.-_/:".contains(before) { return nil }
            }
            let raw = LinkDetector.trimmed(String(text[range]))
            let full = raw.contains("://") ? raw : "http://" + raw
            guard let url = URL(string: full), let address = LocalWebAddress(url: url) else { return nil }
            return (range.lowerBound..<text.index(range.lowerBound, offsetBy: raw.count), address)
        }
    }
}
