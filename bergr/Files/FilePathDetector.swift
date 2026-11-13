import Foundation

/// A file the agent mentioned: a path as written, with an optional line and column.
nonisolated struct FileRef: Hashable, Identifiable, Sendable {
    var path: String
    var line: Int?
    var col: Int?
    var id: String { "\(path):\(line ?? 0):\(col ?? 0)" }

    static let scheme = "bergr-file"

    /// The link a mention carries, so a tap in text reaches the app's `openURL` handler.
    var url: URL? {
        var c = URLComponents()
        c.scheme = Self.scheme
        c.host = "open"
        var items = [URLQueryItem(name: "path", value: path)]
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if let col { items.append(URLQueryItem(name: "col", value: String(col))) }
        c.queryItems = items
        return c.url
    }

    init(path: String, line: Int? = nil, col: Int? = nil) {
        self.path = path
        self.line = line
        self.col = col
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let path = items.first(where: { $0.name == "path" })?.value, !path.isEmpty else { return nil }
        self.path = path
        line = items.first { $0.name == "line" }?.value.flatMap(Int.init)
        col = items.first { $0.name == "col" }?.value.flatMap(Int.init)
    }
}

/// Finds file paths in chat text. A path is `src/foo.swift`, `./x`, `/abs/path`, `~/x` or `C:\x`,
/// with an optional `:line` or `:line:col`. Words, URLs and version numbers are left alone.
nonisolated enum FilePathDetector {
    struct Match: Equatable {
        /// Character offsets into the scanned text.
        var range: Range<Int>
        var ref: FileRef
    }

    static let extensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "cs", "java", "kt", "kts", "scala", "go", "rs", "rb", "py",
        "pyi", "js", "jsx", "mjs", "cjs", "ts", "tsx", "php", "pl", "lua", "dart", "ex", "exs", "erl", "hs",
        "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd", "json", "jsonl", "yaml", "yml", "toml", "ini", "cfg", "conf",
        "plist", "xml", "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "md", "mdx", "txt", "rst",
        "csv", "tsv", "sql", "graphql", "proto", "lock", "log", "env", "xcconfig", "pbxproj", "entitlements",
        "storyboard", "xib", "strings", "gradle", "properties", "tf", "mk", "cmake",
        "patch", "diff", "pdf", "png", "jpg", "jpeg", "gif", "svg", "webp", "ipynb", "zig", "nix", "gitignore",
    ]

    private static let wellKnownNames: Set<String> = [
        "Makefile", "Dockerfile", "Podfile", "Gemfile", "Rakefile", "LICENSE", "README", "Package.resolved",
    ]

    /// The mentions in `text`, in order.
    static func matches(in text: String) -> [Match] {
        let chars = Array(text)
        var result: [Match] = []
        var i = 0
        while i < chars.count {
            if isSeparator(chars[i]) { i += 1; continue }
            var j = i
            while j < chars.count, !isSeparator(chars[j]) { j += 1 }
            // Trim sentence punctuation around the token ("see src/a.swift.", "(src/a.swift)").
            var lo = i, hi = j
            while lo < hi, "([{<\"'`".contains(chars[lo]) { lo += 1 }
            while hi > lo, ".,;:!?)]}>\"'`".contains(chars[hi - 1]) { hi -= 1 }
            if lo < hi, let ref = ref(String(chars[lo..<hi])) {
                result.append(Match(range: lo..<hi, ref: ref))
            }
            i = j
        }
        return result
    }

    /// The path in a whole string (a code span, a tool summary), or nil when it isn't one.
    static func ref(_ token: String) -> FileRef? {
        var s = token.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.count <= 400 else { return nil }
        let lower = s.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || lower.hasPrefix("mailto:") { return nil }
        var line: Int?, col: Int?
        // `#L42` as GitHub writes it, then `:line` and `:line:col`.
        if let r = s.range(of: #"#L\d+(-L?\d+)?$"#, options: .regularExpression) {
            line = Int(s[r].dropFirst(2).prefix { $0.isNumber })
            s.removeSubrange(r)
        } else if let r = s.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
            let parts = s[r].split(separator: ":").compactMap { Int($0) }
            line = parts.first
            col = parts.count > 1 ? parts[1] : nil
            s.removeSubrange(r)
        }
        if let l = line, l < 1 { return nil }
        guard isPath(s) else { return nil }
        return FileRef(path: s, line: line, col: col)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c.isWhitespace || c == "," || c == ";" || c == "|" || c == "=" || c == "\u{201C}" || c == "\u{201D}"
    }

    private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.-/~@+\\:"))

    private static func isPath(_ s: String) -> Bool {
        guard s.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let windowsDrive = s.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
        let body = windowsDrive ? String(s.dropFirst(3)) : s
        // A colon left over is not a path (`key:value`, `std::vector`) except the drive's.
        if body.contains(":") { return false }
        // An email address.
        if s.contains("@"), !s.contains("/") { return false }
        let rooted = windowsDrive || s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../")
        let parts = body.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        guard let last = parts.last else { return false }
        // Something must be a name, not only dots and slashes.
        guard parts.contains(where: { $0.contains { $0.isLetter || $0.isNumber } }) else { return false }
        let hasExtension = hasKnownExtension(last)
        let slashes = s.contains("/") || s.contains("\\")
        if rooted {
            // `/compact` is a command, `/tmp/x` and `/etc/hosts` are paths; `~/x` and `./x` always are.
            if s.hasPrefix("/"), parts.count < 2, !hasExtension { return false }
            return true
        }
        if slashes { return hasExtension || wellKnownNames.contains(last) }
        return hasExtension
    }

    private static func hasKnownExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return extensions.contains(name[name.index(after: dot)...].lowercased())
    }

    // MARK: Resolving

    /// The path as the agent's machine should read it: relative paths joined to `cwd` and tidied
    /// (`.` and `..` folded). `~` stays for the machine's shell to expand.
    static func resolve(_ path: String, cwd: String, windows: Bool = false) -> String {
        let sep: Character = windows ? "\\" : "/"
        let p = windows ? path.replacingOccurrences(of: "/", with: "\\") : path
        let drive = p.range(of: #"^[A-Za-z]:\\"#, options: .regularExpression) != nil
        if p.hasPrefix("~") || p.first == sep || drive { return normalize(p, sep: sep) }
        var base = windows ? cwd.replacingOccurrences(of: "/", with: "\\") : cwd
        if base.isEmpty { return normalize(p, sep: sep) }
        while base.count > 1, base.last == sep { base.removeLast() }
        return normalize(base + String(sep) + p, sep: sep)
    }

    private static func normalize(_ path: String, sep: Character) -> String {
        var prefix = ""
        var rest = Substring(path)
        if rest.hasPrefix("~") {
            prefix = "~"
            rest = rest.dropFirst()
        } else if rest.first == sep {
            prefix = String(sep)
        } else if rest.count >= 2, rest[rest.index(after: rest.startIndex)] == ":" {
            prefix = String(rest.prefix(2))
            rest = rest.dropFirst(2)
        }
        var out: [Substring] = []
        for part in rest.split(separator: sep, omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let l = out.last, l != ".." { out.removeLast(); continue }
            if part == ".." && !prefix.isEmpty { continue }
            out.append(part)
        }
        let joined = out.joined(separator: String(sep))
        if prefix.isEmpty { return joined }
        if prefix == String(sep) { return prefix + joined }
        return prefix + String(sep) + joined
    }

    // MARK: Linking

    /// `text` with each path a link (for text that isn't markdown, like a tool's summary).
    static func linkified(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        link(&result)
        return result
    }

    /// Makes each path in `text` a link, leaving ranges that already link elsewhere.
    static func link(_ text: inout AttributedString) {
        let plain = String(text.characters)
        for m in matches(in: plain) {
            let lo = text.characters.index(text.startIndex, offsetBy: m.range.lowerBound)
            let hi = text.characters.index(text.startIndex, offsetBy: m.range.upperBound)
            if text[lo..<hi].runs.contains(where: { $0.link != nil }) { continue }
            text[lo..<hi].link = m.ref.url
        }
    }
}
