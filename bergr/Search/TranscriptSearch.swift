import Foundation
import HerdrKit

/// One conversation that matched, as `search-transcripts.py` reports it.
struct SearchHit: Decodable, Identifiable, Equatable, Sendable {
    let agent: String
    let role: String
    let path: String
    let session: String
    let cwd: String
    let title: String
    let snippet: String
    /// When the conversation file last changed (seconds since the epoch).
    let ts: Double

    var id: String { "\(agent)|\(session)|\(path)" }
    var date: Date { Date(timeIntervalSince1970: ts) }
    var folder: String { (cwd as NSString).lastPathComponent }
    var agentName: String { agent == "codex" ? "Codex" : "Claude" }
    var displayTitle: String { title.isEmpty ? (folder.isEmpty ? session : folder) : title }
}

struct SearchResponse: Decodable, Equatable, Sendable {
    let hits: [SearchHit]
    let truncated: Bool

    /// The helper's one JSON line; anything printed before it (a login banner) is skipped.
    static func decode(_ output: String) throws -> SearchResponse {
        for line in output.split(whereSeparator: \.isNewline).reversed() where line.hasPrefix("{") {
            if let data = line.data(using: .utf8), let r = try? JSONDecoder().decode(SearchResponse.self, from: data) {
                return r
            }
        }
        throw TranscriptSearchError.badAnswer
    }
}

enum TranscriptSearchError: LocalizedError {
    case badAnswer, noScript
    var errorDescription: String? {
        switch self {
        case .badAnswer: "The machine's answer wasn't a search result. Search needs Python 3 there."
        case .noScript: "The search helper is missing from the app."
        }
    }
}

enum TranscriptSearch {
    static let script: String? = Bundle.main.url(forResource: "search-transcripts", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Same two-stage launch as the chat helper: the command line carries a tiny stage 1 that execs
    /// the first line of stdin, which holds the query and the script (nothing passes through shell
    /// parsing; stage 1 has no spaces, `$` or double quotes, so cmd and PowerShell leave it alone).
    static func command(windows: Bool) -> String {
        let stage1 = "S=__import__('sys');exec(S.stdin.buffer.readline())"
        if windows {
            return "cmd /d /s /c \"set PATH=%LOCALAPPDATA%\\Programs\\Python\\Python313;%PATH%&& python.exe -I -u -c \(stage1)\""
        }
        return "python3 -I -u -c \"\(stage1)\""
    }

    static func input(query: String, script: String) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["q": query])
        let line = "import base64,json;D=json.loads(base64.b64decode('\(payload.base64EncodedString())'));"
            + "exec(base64.b64decode('\(Data(script.utf8).base64EncodedString())'))"
        return Data((line + "\n").utf8)
    }

    /// Runs the search on one machine; bounded by the helper's 5 s plus the connection's slack.
    @MainActor
    static func run(query: String, on session: HostSession) async throws -> SearchResponse {
        guard let script else { throw TranscriptSearchError.noScript }
        let input = try input(query: query, script: script)
        let command = command(windows: session.isWindowsHost)
        return try await withThrowingTaskGroup(of: SearchResponse.self) { group in
            group.addTask { @MainActor in
                let pipe = try await session.openExec(command)
                defer { pipe.close() }
                try await pipe.write(input)
                var out = Data()
                do {
                    for try await chunk in pipe.output {
                        out.append(chunk)
                        if out.count > 400_000 { break }
                    }
                } catch {
                    if out.isEmpty { throw error }
                }
                return try SearchResponse.decode(String(decoding: out, as: UTF8.self))
            }
            group.addTask {
                try await Task.sleep(for: .seconds(9))
                throw CommandTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// The live terminal showing this conversation: the session ID in its launch command, else
    /// the same agent in the same folder, most recently active. Nil when none is live.
    static func liveTerminal(for hit: SearchHit, in terminals: [Terminal]) -> Terminal? {
        let live = terminals.filter(\.isLive)
        let agent = hit.agent == "codex" ? ChatAgent.codex : .claude
        let mine = live.filter { ChatAgent.detect($0) == agent }
        if let byID = mine.first(where: { ChatAgent.sessionHint(argv: $0.argv) == hit.session }) { return byID }
        guard !hit.cwd.isEmpty else { return nil }
        return mine.filter { ($0.foreground?.cwd ?? $0.cwd) == hit.cwd }
            .max { ($0.statusMs ?? $0.createdMs) < ($1.statusMs ?? $1.createdMs) }
    }
}

/// One machine's search outcome.
struct MachineHits: Identifiable {
    let host: Host
    var hits: [SearchHit] = []
    var truncated = false
    var error: String?
    var searching = true
    var id: Host.ID { host.id }
}

/// Searches every connected machine at once; a newer search cancels the one before.
@Observable
@MainActor
final class TranscriptSearchModel {
    private(set) var results: [MachineHits] = []
    private(set) var query = ""
    /// A hit with no live agent, shown as an alert.
    var info: SearchHit?
    private var task: Task<Void, Never>?

    var isSearching: Bool { results.contains(where: \.searching) }

    func search(_ query: String, machines: [(host: Host, session: HostSession)]) {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = q
        guard !q.isEmpty else { results = []; return }
        let targets = machines.filter { $0.session.canRunCommands && $0.session.state == .connected }
        results = targets.map { MachineHits(host: $0.host) }
        task = Task { [weak self] in
            await withTaskGroup(of: (Host.ID, Result<SearchResponse, Error>).self) { group in
                for (host, session) in targets {
                    group.addTask { @MainActor in
                        do { return (host.id, .success(try await TranscriptSearch.run(query: q, on: session))) }
                        catch { return (host.id, .failure(error)) }
                    }
                }
                for await (id, result) in group {
                    guard !Task.isCancelled, let self, let i = self.results.firstIndex(where: { $0.id == id }) else { continue }
                    self.results[i].searching = false
                    switch result {
                    case .success(let r): self.results[i].hits = r.hits; self.results[i].truncated = r.truncated
                    case .failure(let e): self.results[i].error = e.localizedDescription
                    }
                }
            }
        }
    }

    func clear() { task?.cancel(); results = []; query = "" }
}
