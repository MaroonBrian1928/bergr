import Foundation
import HerdrKit
#if canImport(FoundationModels)
import FoundationModels
#endif

/// One chat item as the digest sees it.
nonisolated struct DigestLine: Equatable, Sendable {
    enum Role: Sendable { case user, assistant, tool }
    let role: Role
    let text: String
}

nonisolated enum DigestKind: String, Sendable {
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
nonisolated struct DigestContext: Sendable {
    var title: String
    var kind: DigestKind
    var lines: [DigestLine]
    var statusMessage: String?
}

/// Writes the one-sentence summary. A fake stands in for the model in tests.
nonisolated protocol DigestSummarizing: Sendable {
    /// Nil when it can't (model unavailable, or it failed): the caller falls back.
    func summarize(_ context: DigestContext) async -> String?
}

nonisolated enum AwayDigest {
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

/// Apple's on-device model, through `OnDeviceText` (3 s timeout, refusals dropped). Unavailable
/// (Apple Intelligence off, unsupported device) returns nil.
nonisolated struct FoundationModelsSummarizer: DigestSummarizing {
    var writer: OnDeviceTextWriting = OnDeviceText.shared
    var timeout: Duration = .seconds(3)

    func summarize(_ context: DigestContext) async -> String? {
        let material = AwayDigest.material(context)
        guard !material.isEmpty else { return nil }
        return await writer.write(
            instructions: "Summarize in one short sentence what a coding agent did, from its recent conversation. Plain text, no markdown, under 25 words.",
            prompt: "Agent \"\(context.title)\" is now \(context.kind.label.lowercased()).\n\n\(material)",
            timeout: timeout)
    }
}

extension AwayDigest {
    /// Total transcript characters sent to the model per agent.
    static let maxInputCharacters = 2000

    /// The newest chat lines that fit in `limit` characters (each cut to 400), oldest first; the
    /// status message when there is no chat.
    static func material(_ context: DigestContext, limit: Int = maxInputCharacters) -> String {
        var picked: [String] = []
        var total = 0
        for line in context.lines.reversed() {
            let who = switch line.role { case .user: "User"; case .assistant: "Agent"; case .tool: "Tool" }
            var text = "\(who): \(truncate(line.text, to: 400))"
            let room = limit - total - (picked.isEmpty ? 0 : 1)
            if room <= 0 { break }
            if text.count > room { text = String(text.prefix(room)) }
            picked.append(text)
            total += text.count + (picked.count > 1 ? 1 : 0)
        }
        let transcript = picked.reversed().joined(separator: "\n")
        return transcript.isEmpty ? truncate(context.statusMessage ?? "", to: limit) : transcript
    }

    /// Summaries for `contexts`, at most `maxConcurrent` at a time, each cut off at `timeout` and
    /// replaced by the plain fallback when the summarizer is nil, fails or is too slow.
    static func summaries(
        _ contexts: [(id: String, context: DigestContext)], summarizer: DigestSummarizing,
        maxConcurrent: Int = 2, timeout: Duration = .seconds(3),
        deliver: @escaping @Sendable (String, String) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func add(_ item: (id: String, context: DigestContext)) {
                group.addTask {
                    let text = await OnDeviceText.race(timeout: timeout) { await summarizer.summarize(item.context) }
                    await deliver(item.id, text ?? fallbackSummary(item.context))
                }
            }
            while next < min(max(1, maxConcurrent), contexts.count) { add(contexts[next]); next += 1 }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); continue }
                if next < contexts.count { add(contexts[next]); next += 1 }
            }
        }
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
            var entry = Entry(id: "\(c.host.id.uuidString)|\(c.terminal.address)", host: c.host.id,
                              address: c.terminal.address, machine: c.machine, title: title, kind: kind)
            // The demo's agents bring their sentence with them (fixed text; the model isn't asked).
            if c.host.isDemo { entry.summary = DemoChat.digest[c.terminal.address] ?? c.terminal.status?.msg ?? "" }
            return (entry, DigestContext(title: title, kind: kind, lines: c.lines ?? [],
                                         statusMessage: c.terminal.status?.msg))
        }
        entries = contexts.map(\.0)
        guard !contexts.isEmpty else { return }
        task?.cancel()
        let summarizer = summarizer
        let items = contexts.filter { $0.0.summary == nil }.map { (id: $0.0.id, context: $0.1) }
        task = Task { [weak self] in
            await AwayDigest.summaries(items, summarizer: summarizer) { id, text in
                await MainActor.run {
                    guard let self, let i = self.entries.firstIndex(where: { $0.id == id }) else { return }
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
