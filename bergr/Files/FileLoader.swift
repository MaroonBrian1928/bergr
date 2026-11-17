import Foundation
import SSHTransport

/// Reads one file from the agent's machine over the command channel, capped like the Changes sheet:
/// 4000 lines and 1 MB.
nonisolated struct FileLoader: Sendable {
    enum Result: Equatable, Sendable {
        case text(lines: [String], truncated: Bool)
        case notFound
        case binary
        case failed(String)
    }

    typealias Runner = @Sendable (String) async throws -> String

    static let lineCap = 4000
    static let byteCap = 1_048_576
    /// The helper's first output line says what it found; the file follows.
    static let okMarker = "BERGR:ok"
    static let notFoundMarker = "BERGR:notfound"
    static let binaryMarker = "BERGR:binary"

    let run: Runner
    let windows: Bool

    init(windows: Bool = false, run: @escaping Runner) {
        self.windows = windows
        self.run = run
    }

    func load(_ ref: FileRef, cwd: String) async -> Result {
        let path = FilePathDetector.resolve(ref.path, cwd: cwd, windows: windows)
        let output: String
        do {
            output = try await run(windows ? Self.windowsCommand(path) : Self.posixCommand(path))
        } catch {
            if windows, case SSHTransportError.commandFailed = error { return .notFound }
            return .failed(error.localizedDescription)
        }
        return windows ? Self.parseWindows(output) : Self.parsePosix(output)
    }

    // MARK: Commands

    /// `sh -c` with the path as `$1`, so it runs the same under the user's login shell, whatever it is.
    /// Prints a marker line, then (for a text file) the first byte of the cap plus one, to tell "too big" from "just fits".
    static func posixCommand(_ path: String) -> String {
        let script = """
        f=$1; case "$f" in "~") f=$HOME;; "~/"*) f="$HOME/${f#"~/"}";; esac; \
        if [ ! -f "$f" ]; then echo \(notFoundMarker); exit 0; fi; \
        a=$(head -c 8192 "$f" | wc -c); b=$(head -c 8192 "$f" | tr -d '\\000' | wc -c); \
        if [ "$a" != "$b" ]; then echo \(binaryMarker); exit 0; fi; \
        echo \(okMarker); head -c \(byteCap + 1) "$f"
        """
        return "sh -c \(quote(script)) sh \(quote(path))"
    }

    /// cmd.exe's `type`: a missing file exits non-zero. `%USERPROFILE%` stands in for `~`.
    static func windowsCommand(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\"", with: "")
        if p == "~" { p = "%USERPROFILE%" } else if p.hasPrefix("~\\") { p = "%USERPROFILE%" + p.dropFirst() }
        return "type \"\(p)\""
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Parsing

    static func parsePosix(_ output: String) -> Result {
        guard let nl = output.firstIndex(of: "\n") else {
            switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
            case notFoundMarker: return .notFound
            case binaryMarker: return .binary
            case okMarker: return .text(lines: [], truncated: false)
            default: return .failed(output.isEmpty ? "The machine sent nothing back." : output)
            }
        }
        switch output[..<nl].trimmingCharacters(in: .whitespaces) {
        case notFoundMarker: return .notFound
        case binaryMarker: return .binary
        case okMarker: return cap(String(output[output.index(after: nl)...]))
        default: return .failed("Unexpected answer from the machine.")
        }
    }

    static func parseWindows(_ output: String) -> Result {
        if output.contains("\u{0}") { return .binary }
        return cap(output)
    }

    private static func cap(_ text: String) -> Result {
        var truncated = text.utf8.count > byteCap
        var body = Substring(text)
        if truncated {
            body = Substring(String(decoding: Array(text.utf8.prefix(byteCap)), as: UTF8.self))
        }
        if body.utf8.contains(0) { return .binary }
        // "\r\n" is one Character in Swift, so split on the line ending itself.
        var lines = body.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // A trailing newline ends the last line; it doesn't start another.
        if lines.last == "", !truncated || lines.count > 1 { lines.removeLast() }
        if lines.count > lineCap {
            lines = Array(lines.prefix(lineCap))
            truncated = true
        }
        return .text(lines: lines, truncated: truncated)
    }
}

// MARK: Images named in a message

/// An image a message names by path ("/tmp/shots/after.png"), shown only when tapped. Safety:
/// the path reaches the machine as a quoted argument (`sh -c … sh <path>`), never as part of the
/// command; only files whose first bytes are PNG, JPEG, GIF, WebP or HEIC are read, and only up
/// to `imageCap`; the bytes are decoded on the device by ImageIO.
extension FileLoader {
    static let imageCap = 10 * 1_048_576
    static let tooBigMarker = "BERGR:toobig"
    static let notImageMarker = "BERGR:notimage"

    enum ImageResult: Equatable, Sendable {
        case image(Data)
        case notFound, tooBig, notImage
        /// Not found, and where it looked: "user@host /the/path".
        case notFoundAt(String)
        case failed(String)
    }

    /// Absolute or home-relative paths ending in an image extension, in order, at most four.
    static func imagePaths(in text: String) -> [String] {
        var out: [String] = []
        for match in text.matches(of: /(?:~\/|\/)[^\s`'"()<>\[\]]+\.(?i:png|jpe?g|gif|webp|heic)\b/) {
            let path = String(match.output)
            if !out.contains(path) { out.append(path) }
            if out.count == 4 { break }
        }
        return out
    }

    static func posixImageCommand(_ path: String) -> String {
        let script = """
        f=$1; case "$f" in "~/"*) f="$HOME/${f#"~/"}";; esac; \
        if [ ! -f "$f" ]; then echo "\(notFoundMarker) $(id -un)@$(hostname -s) $f"; exit 0; fi; \
        n=$(wc -c < "$f" | tr -d ' '); if [ "$n" -gt \(imageCap) ]; then echo \(tooBigMarker); exit 0; fi; \
        m=$(head -c 12 "$f" | od -An -tx1 | tr -d ' \\n'); \
        case "$m" in 89504e47*|ffd8ff*|47494638*|52494646????????57454250|????????66747970*) ;; \
        *) echo \(notImageMarker); exit 0;; esac; \
        echo \(okMarker); base64 < "$f"
        """
        return "sh -c \(quote(script)) sh \(quote(path))"
    }

    func loadImage(_ path: String) async -> ImageResult {
        guard !windows else { return .failed("Images from Windows machines aren't shown yet.") }
        let output: String
        do { output = try await run(Self.posixImageCommand(path)) } catch { return .failed(error.localizedDescription) }
        return Self.parseImage(output)
    }

    static func parseImage(_ output: String) -> ImageResult {
        let lines = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        switch lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) ?? "" {
        case let first where first.hasPrefix(notFoundMarker + " "):
            return .notFoundAt(String(first.dropFirst(notFoundMarker.count + 1)))
        case notFoundMarker: return .notFound
        case tooBigMarker: return .tooBig
        case notImageMarker: return .notImage
        case okMarker:
            guard lines.count == 2,
                  let data = Data(base64Encoded: String(lines[1]), options: .ignoreUnknownCharacters),
                  !data.isEmpty, data.count <= imageCap else { return .failed("The image didn't come through.") }
            return .image(data)
        default: return .failed(output.isEmpty ? "The machine sent nothing back." : String(output.prefix(120)))
        }
    }
}
