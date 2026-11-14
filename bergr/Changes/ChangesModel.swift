import Foundation
import Observation
import SSHTransport

/// Loads what an agent changed in its working folder, over the machine's command channel.
@Observable @MainActor
final class ChangesModel {
    enum Phase: Equatable { case loading, notARepo, failed(String), loaded }
    enum DiffState: Equatable { case loading, loaded(GitParsing.FileDiff), failed(String) }
    /// The one-sentence summary; `.none` means no row.
    enum SummaryState: Equatable { case none, writing, written(String) }

    typealias Runner = @Sendable (String) async throws -> String

    private(set) var phase = Phase.loading
    private(set) var status = GitParsing.Status()
    private(set) var stat = GitParsing.Stat()
    private(set) var diffs: [String: DiffState] = [:]
    private(set) var summary = SummaryState.none
    /// All changes since HEAD, or only what the last turn did (against the helper's turn snapshot).
    enum Scope: Hashable { case all, lastTurn }
    enum TurnSnapshot: Equatable { case unknown, available, unavailable }
    private(set) var scope = Scope.all
    private(set) var turnSnapshot = TurnSnapshot.unknown
    /// Untracked files that appeared since the last turn started (Last turn scope).
    private(set) var newFiles: [String] = []
    static let turnUnavailableText = "Turn snapshots need the push helper v18+."
    let folder: String
    let address: String?
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let expensive: Bool
    @ObservationIgnored private let lastReply: String?
    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private var statText = ""
    @ObservationIgnored var summaryTask: Task<Void, Never>?
    static let prefetchLimit = 10
    private static let diffLineCap = 4000

    init(folder: String, address: String? = nil, expensive: Bool? = nil, lastReply: String? = nil,
         writer: OnDeviceTextWriting = OnDeviceText.shared, run: @escaping Runner) {
        self.folder = folder
        self.address = address
        self.expensive = expensive ?? NetworkWatcher.shared.isExpensive
        self.lastReply = lastReply
        self.writer = writer
        self.run = run
    }

    /// `git -C "<folder>"`: no `cd` or `&&`, so it runs the same under sh, cmd and PowerShell.
    nonisolated static func git(_ folder: String, _ args: String) -> String {
        var f = folder
        while f.count > 1, f.hasSuffix("\\") || f.hasSuffix("/") { f.removeLast() }
        return "git -C \"\(f.replacingOccurrences(of: "\"", with: ""))\" \(args)"
    }

    /// The helper's ref component for a terminal address (same as `ref_name` in bergr-notify.py).
    nonisolated static func turnRefName(_ address: String) -> String {
        let name = String(address.unicodeScalars.map { s -> Character in
            switch s {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": return Character(s)
            default: return "_"
            }
        })
        return name.isEmpty ? "_" : name
    }

    var turnRef: String? { address.map { "refs/bergr/turns/" + Self.turnRefName($0) } }
    private var turnUntrackedRef: String? { address.map { "refs/bergr/turns-untracked/" + Self.turnRefName($0) } }

    /// What the diffs compare the working tree with.
    var base: String { scope == .lastTurn ? (turnRef ?? "HEAD") : "HEAD" }

    nonisolated static func diffStatCommand(folder: String, base: String) -> String {
        git(folder, "diff \(base) --stat=120 --no-color")
    }

    nonisolated static func fileDiffCommand(folder: String, base: String, path: String) -> String {
        git(folder, "diff \(base) --no-color --no-ext-diff -- \"\(path)\"")
    }

    func setScope(_ new: Scope) async {
        guard new != scope, new == .all || turnSnapshot == .available else { return }
        scope = new
        await load(showSpinner: false)
    }

    private func probeTurnSnapshot() async {
        guard let ref = turnRef else { turnSnapshot = .unavailable; return }
        turnSnapshot = (try? await run(Self.git(folder, "rev-parse --verify -q \(ref)"))) == nil ? .unavailable : .available
        if turnSnapshot == .unavailable { scope = .all }
    }

    private func loadNewFiles() async {
        guard scope == .lastTurn else { newFiles = []; return }
        let now = GitParsing.fileList((try? await run(Self.git(folder, "ls-files --others --exclude-standard"))) ?? "")
        var before: [String]?
        if let ref = turnUntrackedRef, let text = try? await run(Self.git(folder, "cat-file -p \(ref)")) {
            before = GitParsing.fileList(text)
        }
        newFiles = GitParsing.newFiles(now: now, before: before)
    }

    func load(showSpinner: Bool = true) async {
        if showSpinner { phase = .loading }
        diffs = [:]
        summaryTask?.cancel()
        summary = .none
        do {
            let out = try await run(Self.git(folder, "status --porcelain=v1 -b"))
            status = GitParsing.status(out)
            if scope == .all || turnSnapshot == .unknown { await probeTurnSnapshot() }
            let text: String
            if scope == .lastTurn {
                text = try await run(Self.diffStatCommand(folder: folder, base: base))
            } else {
                do { text = try await run(Self.diffStatCommand(folder: folder, base: "HEAD")) }
                catch { text = (try? await run(Self.git(folder, "diff --stat=120 --no-color"))) ?? "" }
            }
            await loadNewFiles()
            statText = text
            stat = GitParsing.stat(text)
            phase = .loaded
            summary = .writing
            summaryTask = Task { await self.writeSummary() }
        } catch {
            let err = Self.stderr(of: error)
            // git exits 128 on its fatal errors (not a repository, no such folder, a repo owned by
            // another user); over SSH its message may not come back, only the code.
            let notRepo = err.lowercased().contains("not a git repository")
                || error.localizedDescription.contains("exited with 128")
            phase = notRepo ? .notARepo : .failed(err.isEmpty ? error.localizedDescription : err)
            return
        }
        if !expensive {
            for file in stat.files.prefix(Self.prefetchLimit) { await loadDiff(file.path) }
        }
    }

    /// Writes the summary from the stat, the first lines of the combined diff (not on expensive
    /// networks) and the agent's last reply. Runs beside the sheet; a nil write hides the row.
    private func writeSummary() async {
        var head = ""
        if !expensive, !statText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                head = ChangesSummary.diffHead(try await run(Self.git(folder, "diff \(base) --no-color --no-ext-diff")))
            } catch {
                let fallback = (try? await run(Self.git(folder, "diff --no-color --no-ext-diff"))) ?? ""
                head = ChangesSummary.diffHead(fallback)
            }
        }
        guard !Task.isCancelled else { return }
        guard let prompt = ChangesSummary.prompt(stat: statText, diffHead: head, reply: lastReply) else {
            summary = .none
            return
        }
        let written = await writer.write(instructions: ChangesSummary.instructions, prompt: prompt,
                                         timeout: ChangesSummary.timeout)
        guard !Task.isCancelled else { return }
        if let written, !written.isEmpty { summary = .written(written) } else { summary = .none }
    }

    private nonisolated static func stderr(of error: Error) -> String {
        if case SSHTransportError.commandFailed(_, let stderr) = error { return stderr }
        return ""
    }

    func loadDiff(_ path: String) async {
        if case .loaded = diffs[path] { return }
        diffs[path] = .loading
        do {
            let text: String
            if scope == .lastTurn {
                text = try await run(Self.fileDiffCommand(folder: folder, base: base, path: path))
            } else {
                do { text = try await run(Self.fileDiffCommand(folder: folder, base: "HEAD", path: path)) }
                catch { text = try await run(Self.git(folder, "diff --no-color --no-ext-diff -- \"\(path)\"")) }
            }
            let capped = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.diffLineCap).joined(separator: "\n")
            diffs[path] = .loaded(GitParsing.diff(capped))
        } catch {
            diffs[path] = .failed(error.localizedDescription)
        }
    }
}
