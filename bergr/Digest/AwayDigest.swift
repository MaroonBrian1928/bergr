import Foundation
import HerdrKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One chat item as the digest sees it.
struct DigestLine: Equatable, Sendable {
    enum Role: Sendable { case user, assistant, tool }
    let role: Role
    let text: String
}

enum DigestKind: String, Sendable {
    case finished, needsYou, error

    var label: String {
        switch self {
        case .finished: "Finished"
        case .needsYou: "Needs you"
        case .error: "Error"
        }
    }

    init?(_ state: AgentState?) {
        switch state {
        case .done: self = .finished
        case .needsYou: self = .needsYou
        case .error: self = .error
        default: return nil
        }
    }
}

/// What the summary is written from: the agent's last chat items when its chat is followed, plus
/// its status message.
struct DigestContext: Sendable {
    var title: String
    var kind: DigestKind
    var lines: [DigestLine]
    var statusMessage: String?
}

/// Writes the one-sentence summary. A fake stands in for the model in tests.
protocol DigestSummarizing: Sendable {
    /// Nil when it can't (model unavailable, or it failed): the caller falls back.
    func summarize(_ context: DigestContext) async -> String?
}

enum AwayDigest {
    /// Away this long (seconds) before the card shows.
    static let threshold: TimeInterval = 15 * 60

    /// Agents that changed state to finished / needs you / error after `since`, newest first.
    static func changed<T>(_ items: [T], since: Date, terminal: (T) -> Terminal) -> [T] {
        let sinceMs = UInt64(max(0, since.timeIntervalSince1970) * 1000)
        return items.filter { item in
            let t = terminal(item)
            guard t.isLive, t.isAgent, DigestKind(t.agentState) != nil, let at = t.statusMs else { return false }
            return at >= sinceMs
        }.sorted { (terminal($0).statusMs ?? 0) > (terminal($1).statusMs ?? 0) }
    }

    /// Without the model: the last sentence the agent wrote (else its status message, else the
    /// state), cut to fit.
    static func fallbackSummary(_ context: DigestContext, limit: Int = 140) -> String {
        let assistant = context.lines.last { $0.role == .assistant && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let source = assistant?.text ?? context.statusMessage ?? ""
        let sentence = lastSentence(of: source)
        if sentence.isEmpty { return context.kind.label }
        return truncate(sentence, to: limit)
    }

    static func lastSentence(of text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = flat.last else { return "" }
        var sentences: [String] = []
        last.enumerateSubstrings(in: last.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        return sentences.last ?? last
    }

    static func truncate(_ s: String, to limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Apple's on-device model. Unavailable (Apple Intelligence off, unsupported device) returns nil.
struct FoundationModelsSummarizer: DigestSummarizing {
    func summarize(_ context: DigestContext) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let transcript = context.lines.suffix(20).map { line -> String in
            let who = switch line.role { case .user: "User"; case .assistant: "Agent"; case .tool: "Tool" }
            return "\(who): \(AwayDigest.truncate(line.text, to: 400))"
        }.joined(separator: "\n")
        let material = transcript.isEmpty ? (context.statusMessage ?? "") : transcript
        guard !material.isEmpty else { return nil }
        let session = LanguageModelSession(instructions:
            "Summarize in one short sentence what a coding agent did, from its recent conversation. Plain text, no markdown, under 25 words.")
        do {
            let r = try await session.respond(to: "Agent \"\(context.title)\" is now \(context.kind.label.lowercased()).\n\n\(material)")
            let text = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}

/// The card's content; summaries fill in as they finish, never blocking the list.
@Observable
@MainActor
final class AwayDigestModel {
    struct Entry: Identifiable, Equatable {
        let id: String
        let host: Host.ID
        let address: String
        let machine: String
        let title: String
        let kind: DigestKind
        var summary: String?
    }

    private(set) var entries: [Entry] = []
    private var left: Date?
    private var task: Task<Void, Never>?
    private let summarizer: DigestSummarizing

    init(summarizer: DigestSummarizing = FoundationModelsSummarizer()) { self.summarizer = summarizer }

    func appDidLeave(at date: Date = .now) { left = date }

    /// Back in the foreground: after a long enough absence, build the card from `candidates`
    /// (re-read after `settle`, so reconnecting machines can report first).
    func appDidReturn(now: Date = .now, settle: Duration = .seconds(3),
                      candidates: @escaping @MainActor () -> [Candidate]) {
        guard let left, now.timeIntervalSince(left) >= AwayDigest.threshold else { return }
        self.left = nil
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled else { return }
            self?.build(since: left, candidates: candidates())
        }
    }

    struct Candidate {
        let host: Host
        let machine: String
        let terminal: Terminal
        let lines: [DigestLine]?
    }

    func build(since: Date, candidates: [Candidate]) {
        let changed = AwayDigest.changed(candidates, since: since) { $0.terminal }
        let contexts: [(Entry, DigestContext)] = changed.compactMap { c in
            guard let kind = DigestKind(c.terminal.agentState) else { return nil }
            let title = AgentsOrdering.title(c.terminal)
            let entry = Entry(id: "\(c.host.id.uuidString)|\(c.terminal.address)", host: c.host.id,
                              address: c.terminal.address, machine: c.machine, title: title, kind: kind)
            return (entry, DigestContext(title: title, kind: kind, lines: c.lines ?? [],
                                         statusMessage: c.terminal.status?.msg))
        }
        entries = contexts.map(\.0)
        guard !contexts.isEmpty else { return }
        task?.cancel()
        let summarizer = summarizer
        task = Task { [weak self] in
            await withTaskGroup(of: (String, String).self) { group in
                for (entry, context) in contexts {
                    group.addTask {
                        let text = await summarizer.summarize(context) ?? AwayDigest.fallbackSummary(context)
                        return (entry.id, text)
                    }
                }
                for await (id, text) in group {
                    guard !Task.isCancelled, let self, let i = self.entries.firstIndex(where: { $0.id == id }) else { continue }
                    self.entries[i].summary = text
                }
            }
        }
    }

    /// Dismissed: hides the card and stops the summaries.
    func dismiss() {
        task?.cancel()
        task = nil
        entries = []
    }
}
