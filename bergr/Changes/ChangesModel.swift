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
    let folder: String
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let expensive: Bool
    @ObservationIgnored private let lastReply: String?
    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private var statText = ""
    @ObservationIgnored var summaryTask: Task<Void, Never>?
    static let prefetchLimit = 10
    private static let diffLineCap = 4000

    init(folder: String, expensive: Bool? = nil, lastReply: String? = nil,
         writer: OnDeviceTextWriting = OnDeviceText.shared, run: @escaping Runner) {
        self.folder = folder
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

    func load() async {
        phase = .loading
        diffs = [:]
        summaryTask?.cancel()
        summary = .none
        do {
            let out = try await run(Self.git(folder, "status --porcelain=v1 -b"))
            status = GitParsing.status(out)
            let text: String
            do { text = try await run(Self.git(folder, "diff HEAD --stat=120 --no-color")) }
            catch { text = (try? await run(Self.git(folder, "diff --stat=120 --no-color"))) ?? "" }
            statText = text
            stat = GitParsing.stat(text)
            phase = .loaded
            summary = .writing
            summaryTask = Task { await self.writeSummary() }
        } catch {
            let err = Self.stderr(of: error)
            phase = err.lowercased().contains("not a git repository") ? .notARepo
                : .failed(err.isEmpty ? error.localizedDescription : err)
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
                head = ChangesSummary.diffHead(try await run(Self.git(folder, "diff HEAD --no-color --no-ext-diff")))
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
            do { text = try await run(Self.git(folder, "diff HEAD --no-color --no-ext-diff -- \"\(path)\"")) }
            catch { text = try await run(Self.git(folder, "diff --no-color --no-ext-diff -- \"\(path)\"")) }
            let capped = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.diffLineCap).joined(separator: "\n")
            diffs[path] = .loaded(GitParsing.diff(capped))
        } catch {
            diffs[path] = .failed(error.localizedDescription)
        }
    }
}
