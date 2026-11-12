import Foundation
import Observation
import SSHTransport

/// Loads what an agent changed in its working folder, over the machine's command channel.
@Observable @MainActor
final class ChangesModel {
    enum Phase: Equatable { case loading, notARepo, failed(String), loaded }
    enum DiffState: Equatable { case loading, loaded(GitParsing.FileDiff), failed(String) }

    typealias Runner = @Sendable (String) async throws -> String

    private(set) var phase = Phase.loading
    private(set) var status = GitParsing.Status()
    private(set) var stat = GitParsing.Stat()
    private(set) var diffs: [String: DiffState] = [:]
    let folder: String
    @ObservationIgnored private let run: Runner
    @ObservationIgnored private let expensive: Bool
    static let prefetchLimit = 10
    private static let diffLineCap = 4000

    init(folder: String, expensive: Bool? = nil, run: @escaping Runner) {
        self.folder = folder
        self.expensive = expensive ?? NetworkWatcher.shared.isExpensive
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
        do {
            let out = try await run(Self.git(folder, "status --porcelain=v1 -b"))
            status = GitParsing.status(out)
            let statText: String
            do { statText = try await run(Self.git(folder, "diff HEAD --stat=120 --no-color")) }
            catch { statText = (try? await run(Self.git(folder, "diff --stat=120 --no-color"))) ?? "" }
            stat = GitParsing.stat(statText)
            phase = .loaded
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
