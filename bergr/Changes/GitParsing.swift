import Foundation

/// Parsers for the git output the Changes sheet shows. Pure functions, so they're tested apart from SSH.
enum GitParsing {
    struct StatusEntry: Equatable, Identifiable {
        /// Index column and work-tree column of `--porcelain=v1`.
        var x: Character
        var y: Character
        var path: String
        /// The old path of a rename or copy.
        var from: String?
        var id: String { path }
        var isUntracked: Bool { x == "?" }
        var isStaged: Bool { x != " " && x != "?" && x != "!" }
        var label: String {
            if isUntracked { return "new" }
            let c = x != " " ? x : y
            switch c {
            case "M": return "modified"
            case "A": return "added"
            case "D": return "deleted"
            case "R": return "renamed"
            case "C": return "copied"
            case "U": return "conflict"
            default: return "changed"
            }
        }
    }

    struct Status: Equatable {
        var branch: String?
        var upstream: String?
        var ahead = 0
        var behind = 0
        var noCommits = false
        var entries: [StatusEntry] = []
        var untrackedCount: Int { entries.filter(\.isUntracked).count }
        var trackedChanges: [StatusEntry] { entries.filter { !$0.isUntracked } }
    }

    /// `git status --porcelain=v1 -b`.
    static func status(_ text: String) -> Status {
        var result = Status()
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("## ") {
                parseBranch(String(line.dropFirst(3)), into: &result)
                continue
            }
            guard line.count > 3 else { continue }
            let chars = Array(line)
            let rest = String(line.dropFirst(3))
            var path = rest
            var from: String?
            if chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C",
               let arrow = rest.range(of: " -> ") {
                from = unquote(String(rest[..<arrow.lowerBound]))
                path = String(rest[arrow.upperBound...])
            }
            result.entries.append(StatusEntry(x: chars[0], y: chars[1], path: unquote(path), from: from))
        }
        return result
    }

    private static func parseBranch(_ s: String, into r: inout Status) {
        var head = s
        if head.hasPrefix("No commits yet on ") {
            r.noCommits = true
            r.branch = String(head.dropFirst("No commits yet on ".count))
            return
        }
        if head.hasPrefix("HEAD (no branch)") { r.branch = "HEAD (detached)"; return }
        if let bracket = head.range(of: " [", options: .backwards), head.hasSuffix("]") {
            let info = head[bracket.upperBound...].dropLast()
            for part in info.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasPrefix("ahead ") { r.ahead = Int(p.dropFirst(6)) ?? 0 }
                if p.hasPrefix("behind ") { r.behind = Int(p.dropFirst(7)) ?? 0 }
            }
            head = String(head[..<bracket.lowerBound])
        }
        if let dots = head.range(of: "...") {
            r.branch = String(head[..<dots.lowerBound])
            r.upstream = String(head[dots.upperBound...])
        } else {
            r.branch = head
        }
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast())
    }

    struct StatFile: Equatable, Identifiable {
        var path: String
        var changes: Int
        var plus: Int
        var minus: Int
        var binary: Bool
        var id: String { path }
    }

    struct Stat: Equatable {
        var files: [StatFile] = []
        var insertions = 0
        var deletions = 0
    }

    /// `git diff --stat`.
    static func stat(_ text: String) -> Stat {
        var result = Stat()
        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            if line.contains("file") && line.contains("changed") {
                for part in line.split(separator: ",") {
                    let p = part.trimmingCharacters(in: .whitespaces)
                    let n = Int(p.prefix { $0.isNumber }) ?? 0
                    if p.contains("insertion") { result.insertions = n }
                    if p.contains("deletion") { result.deletions = n }
                }
                continue
            }
            guard let bar = line.range(of: " | ", options: .backwards) else { continue }
            let path = line[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = line[bar.upperBound...].trimmingCharacters(in: .whitespaces)
            if tail.hasPrefix("Bin") {
                result.files.append(StatFile(path: path, changes: 0, plus: 0, minus: 0, binary: true))
                continue
            }
            let changes = Int(tail.prefix { $0.isNumber }) ?? 0
            result.files.append(StatFile(path: path, changes: changes,
                                         plus: tail.filter { $0 == "+" }.count,
                                         minus: tail.filter { $0 == "-" }.count, binary: false))
        }
        return result
    }

    struct DiffLine: Equatable {
        enum Kind { case meta, hunk, add, del, context }
        var kind: Kind
        var text: String
    }

    struct Hunk: Equatable {
        var header: String
        var lines: [DiffLine]
    }

    struct FileDiff: Equatable {
        var meta: [String] = []
        var hunks: [Hunk] = []
        var isBinary = false
    }

    /// A unified diff of one file.
    static func diff(_ text: String) -> FileDiff {
        var result = FileDiff()
        var current: Hunk?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("@@") {
                if let current { result.hunks.append(current) }
                current = Hunk(header: line, lines: [])
            } else if current == nil {
                if line.hasPrefix("Binary files") { result.isBinary = true }
                if !line.isEmpty { result.meta.append(line) }
            } else if line.hasPrefix("+") {
                current?.lines.append(DiffLine(kind: .add, text: line))
            } else if line.hasPrefix("-") {
                current?.lines.append(DiffLine(kind: .del, text: line))
            } else if line.hasPrefix("\\") {
                current?.lines.append(DiffLine(kind: .meta, text: line))
            } else {
                current?.lines.append(DiffLine(kind: .context, text: line))
            }
        }
        if var last = current {
            // The text's final newline leaves one empty context line.
            if last.lines.last == DiffLine(kind: .context, text: "") { last.lines.removeLast() }
            result.hunks.append(last)
        }
        return result
    }
}

/// The last test-like command the agent ran, and how its output reads.
enum TestRun {
    enum Verdict { case passed, failed, unknown }

    struct Run: Equatable {
        var command: String
        var output: String
        var verdict: Verdict
    }

    private static let shells: Set<String> = ["bash", "shell", "exec_command", "run_shell_command", "run_command", "execute"]
    private static let patterns = [
        "pytest", "jest", "vitest", "cargo test", "go test", "swift test", "npm test",
        "npm run test", "yarn test", "pnpm test", "just test", "mocha", "rspec", "phpunit", "python -m unittest",
    ]

    static func isTestCommand(_ command: String) -> Bool {
        let c = command.lowercased()
        if c.contains("xcodebuild") { return c.contains(" test") }
        return patterns.contains { c.contains($0) }
    }

    /// The command of a tool row: the last line of its summary (Claude puts a description first).
    static func command(of summary: String) -> String {
        summary.split(separator: "\n").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    static func last(in items: [ChatFeed.Item], output: [String: String]) -> Run? {
        for item in items.reversed() {
            guard case .tool(let name, let summary) = item.kind, shells.contains(name.lowercased()) else { continue }
            let command = command(of: summary)
            guard isTestCommand(command) else { continue }
            let out = output[item.id] ?? ""
            return Run(command: command, output: tail(out), verdict: verdict(out))
        }
        return nil
    }

    static func tail(_ text: String, lines: Int = 20) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func verdict(_ output: String) -> Verdict {
        let o = output.lowercased()
        guard !o.isEmpty else { return .unknown }
        // "0 failed" is a pass; strip it before looking for failure words.
        let cleaned = o.replacingOccurrences(of: "0 failed", with: "").replacingOccurrences(of: "0 failures", with: "")
        let failed = ["** test failed **", "test result: failed", "failures:", "failed", "error:", "traceback", "✗", "✘", "assertionerror"]
        if failed.contains(where: cleaned.contains) { return .failed }
        let passed = ["** test succeeded **", "test result: ok", "passed", "✓", "✔", "0 failed", "0 failures"]
        if passed.contains(where: o.contains) { return .passed }
        return .unknown
    }
}
