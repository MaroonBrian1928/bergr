import Foundation
import HerdrKit

/// Git worktrees for agent sessions: names, paths, commands and the branch shown on rows.
/// Pure functions, so they're tested apart from SSH.
enum Worktrees {
    /// What a git command prints on success, since the command channel doesn't report exit codes.
    static let okMarker = "__BERGR_OK__"

    // MARK: Names

    /// A branch name git accepts, made from what was typed: letters, digits and `._-/` only.
    static func sanitizeBranch(_ text: String) -> String {
        var out = ""
        for ch in text.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isASCII, ch.isLetter || ch.isNumber || "._-/".contains(ch) { out.append(ch) } else { out.append("-") }
        }
        while out.contains("..") { out = out.replacingOccurrences(of: "..", with: ".") }
        while out.contains("//") { out = out.replacingOccurrences(of: "//", with: "/") }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.replacingOccurrences(of: "/.", with: "/")
        let trim = CharacterSet(charactersIn: "-/.")
        out = out.trimmingCharacters(in: trim)
        while out.hasSuffix(".lock") { out = String(out.dropLast(5)).trimmingCharacters(in: trim) }
        return out
    }

    /// `bergr/claude-1115`.
    static func defaultBranch(agent: ChatAgent, date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day], from: date)
        let stamp = String(format: "%02d%02d", c.month ?? 0, c.day ?? 0)
        return "bergr/\(NewSession.command(agent))-\(stamp)"
    }

    /// The branch as a folder-name part: `bergr/claude-1115` becomes `bergr-claude-1115`.
    static func slug(_ branch: String) -> String {
        sanitizeBranch(branch).replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Paths

    /// `<folder>/../<repo>-<slug>` with the separator of the machine.
    static func basePath(folder: String, branch: String, windows: Bool) -> String {
        let sep = windows ? "\\" : "/"
        var parts = folder.split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
        let leading = (!windows && folder.hasPrefix("/")) ? sep : ""
        let repo = parts.popLast() ?? "repo"
        let parent = leading + parts.joined(separator: sep)
        let name = "\(repo)-\(slug(branch))"
        if parent.isEmpty { return name }
        return parent.hasSuffix(sep) ? parent + name : parent + sep + name
    }

    /// The first of `base`, `base-2`, `base-3`… that doesn't exist; never an existing path.
    static func choosePath(base: String, existing: Set<String>) -> String {
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }

    /// The paths tried, in order.
    static func candidates(base: String, count: Int = 20) -> [String] {
        [base] + (2...max(2, count)).map { "\(base)-\($0)" }
    }

    // MARK: Commands

    private static let posixPath = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; "

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func winQuote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" }

    private static func cmd(_ inner: String) -> String { "cmd /d /s /c \"\(inner)\"" }

    /// Prints each of `paths` that exists.
    static func existsCommand(paths: [String], windows isWindows: Bool) -> String {
        if isWindows {
            return cmd(paths.map { "if exist \(winQuote($0)) echo \($0)" }.joined(separator: " & "))
        }
        return "for p in \(paths.map(shellQuote).joined(separator: " ")); do [ -e \"$p\" ] && printf '%s\\n' \"$p\"; done; true"
    }

    static func addCommand(folder: String, branch: String, path: String, windows isWindows: Bool) -> String {
        if isWindows {
            return cmd("git -C \(winQuote(folder)) worktree add -b \(branch) \(winQuote(path)) 2>&1 && echo \(okMarker)")
        }
        return posixPath + "git -C \(shellQuote(folder)) worktree add -b \(shellQuote(branch)) \(shellQuote(path)) </dev/null 2>&1 && echo \(okMarker)"
    }

    /// Never `--force`: git refuses when the worktree has changes.
    static func removeCommand(repo: String, path: String, windows isWindows: Bool) -> String {
        if isWindows {
            return cmd("git -C \(winQuote(repo)) worktree remove \(winQuote(path)) 2>&1 && echo \(okMarker)")
        }
        return posixPath + "git -C \(shellQuote(repo)) worktree remove \(shellQuote(path)) </dev/null 2>&1 && echo \(okMarker)"
    }

    /// One call for the branch, whether it's a linked worktree and whether it's a repo at all.
    static func branchCommand(cwd: String, windows isWindows: Bool) -> String {
        if isWindows {
            return cmd("git -C \(winQuote(cwd)) rev-parse --abbrev-ref HEAD --git-dir --git-common-dir 2>nul")
        }
        return posixPath + "git -C \(shellQuote(cwd)) rev-parse --abbrev-ref HEAD --git-dir --git-common-dir </dev/null 2>/dev/null"
    }

    /// Prints the repo root of `cwd` (git prints forward slashes, also on Windows).
    static func toplevelCommand(cwd: String, windows isWindows: Bool) -> String {
        if isWindows {
            return cmd("git -C \(winQuote(cwd)) rev-parse --show-toplevel 2>nul")
        }
        return posixPath + "git -C \(shellQuote(cwd)) rev-parse --show-toplevel </dev/null 2>/dev/null"
    }

    /// The repo root from `toplevelCommand`, with the machine's separator; nil when it isn't a repo.
    static func parseToplevel(_ output: String, windows isWindows: Bool) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }), !line.hasPrefix("fatal") else { return nil }
        return isWindows ? line.replacingOccurrences(of: "/", with: "\\") : line
    }

    /// The path of `folder` under `root` ("" when it is the root, nil when it isn't inside it).
    static func relativePath(folder: String, root: String) -> String? {
        func norm(_ p: String) -> String {
            var s = p.replacingOccurrences(of: "\\", with: "/")
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        let f = norm(folder), r = norm(root)
        if f == r { return "" }
        guard f.hasPrefix(r.hasSuffix("/") ? r : r + "/") else { return nil }
        return String(f.dropFirst(r.hasSuffix("/") ? r.count : r.count + 1))
    }

    /// `relative` inside the new worktree, with the machine's separator.
    static func startFolder(worktree: String, relative: String, windows isWindows: Bool) -> String {
        guard !relative.isEmpty else { return worktree }
        let sep = isWindows ? "\\" : "/"
        return worktree + sep + relative.replacingOccurrences(of: "/", with: sep)
    }

    /// The command's output without the success marker, for showing an error.
    static func failureText(_ output: String) -> String {
        let text = output.replacingOccurrences(of: okMarker, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "git didn't say why." : text
    }

    static func succeeded(_ output: String) -> Bool { output.contains(okMarker) }

    // MARK: Row info

    struct BranchInfo: Equatable {
        /// nil when HEAD is detached.
        var branch: String?
        var isLinkedWorktree: Bool

        /// "feature/x", or "detached" for a detached HEAD.
        var label: String { branch ?? "detached" }
    }

    /// Parses `rev-parse --abbrev-ref HEAD --git-dir --git-common-dir`; nil when it isn't a repo.
    static func parseBranchInfo(_ output: String) -> BranchInfo? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3, !lines[0].hasPrefix("fatal"), !lines[0].isEmpty else { return nil }
        func norm(_ p: String) -> String {
            var s = p.replacingOccurrences(of: "\\", with: "/")
            while s.count > 1, s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return BranchInfo(branch: lines[0] == "HEAD" ? nil : lines[0],
                          isLinkedWorktree: norm(lines[1]) != norm(lines[2]))
    }

    /// The secondary text of a row: `feature/x` or `feature/x · worktree`.
    static func rowText(_ info: BranchInfo) -> String {
        info.isLinkedWorktree ? "\(info.label) · worktree" : info.label
    }
}

/// Branch info per machine and folder, kept so rows don't ask on every redraw.
@MainActor @Observable
final class BranchInfoStore {
    static let shared = BranchInfoStore()

    struct Key: Hashable { let host: UUID; let cwd: String }
    static let maxAge: TimeInterval = 60

    private(set) var infos: [Key: Worktrees.BranchInfo] = [:]
    @ObservationIgnored private var fetchedAt: [Key: Date] = [:]
    @ObservationIgnored private var inFlight: Set<Key> = []

    func info(host: UUID, cwd: String) -> Worktrees.BranchInfo? { infos[Key(host: host, cwd: cwd)] }

    /// Whether a refresh is due: never fetched, forced, or older than 60 s; never while one is running.
    func isDue(_ key: Key, now: Date, force: Bool) -> Bool {
        if inFlight.contains(key) { return false }
        guard let at = fetchedAt[key] else { return true }
        return force || now.timeIntervalSince(at) >= Self.maxAge
    }

    /// Asks once per distinct folder; a no-op when the cached answer is still fresh.
    func refresh(host: UUID, cwd: String, force: Bool = false, now: Date = .now,
                 fetch: () async -> Worktrees.BranchInfo?) async {
        let key = Key(host: host, cwd: cwd)
        guard !cwd.isEmpty, isDue(key, now: now, force: force) else { return }
        inFlight.insert(key)
        let result = await fetch()
        inFlight.remove(key)
        fetchedAt[key] = now
        infos[key] = result
    }
}

extension BranchInfoStore {
    /// Refreshes over the machine's command channel.
    func refresh(session: HostSession, cwd: String, force: Bool = false) async {
        await refresh(host: session.host.id, cwd: cwd, force: force) {
            guard let out = try? await session.commandOutput(
                Worktrees.branchCommand(cwd: cwd, windows: session.isWindowsHost), timeout: .seconds(8)) else { return nil }
            return Worktrees.parseBranchInfo(out)
        }
    }
}

/// A worktree Bergr made for a session, remembered so End can offer to remove it.
struct WorktreeRecord: Codable, Equatable {
    var repo: String
    var path: String
    var windows: Bool
}

enum WorktreeRegistry {
    private static let key = "bergr.worktrees"

    private static func load() -> [String: WorktreeRecord] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let map = try? JSONDecoder().decode([String: WorktreeRecord].self, from: data) else { return [:] }
        return map
    }

    private static func save(_ map: [String: WorktreeRecord]) {
        if let data = try? JSONEncoder().encode(map) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func id(host: UUID, address: String) -> String { "\(host.uuidString)|\(address)" }
    static func record(host: UUID, address: String) -> WorktreeRecord? { load()[id(host: host, address: address)] }
    static func set(_ record: WorktreeRecord?, host: UUID, address: String) {
        var map = load()
        map[id(host: host, address: address)] = record
        save(map)
    }
}
