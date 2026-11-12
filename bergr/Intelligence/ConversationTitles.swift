import Foundation
import Observation

/// Short titles for conversations, written on the device by `OnDeviceText`. A row shows the
/// conversation's own first message until its title arrives, then swaps. Each conversation is
/// written once: titles are cached by conversation id in memory and in UserDefaults (at most
/// `limit` entries), and at most `maxConcurrent` writes run at a time. A nil reply keeps the old title.
@MainActor @Observable
final class ConversationTitles {
    static let shared = ConversationTitles(writer: OnDeviceText.shared, defaults: .standard)

    static let limit = 500
    static let maxConcurrent = 3
    static let timeout: Duration = .seconds(8)
    static let storageKey = "conversationTitles.v1"

    static let instructions = """
    You name conversations with a coding agent. Reply with a short descriptive title of 3 to 7 words \
    that says what the work is about, like "Fix flaky login redirect test". Plain text only: no quotes, \
    no markdown, no trailing punctuation.
    """

    /// Written titles, by conversation id. Views read it, so they update when a title arrives.
    private(set) var titles: [String: String] = [:]

    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private let defaults: UserDefaults
    /// Ids in the order they were written, oldest first, for trimming.
    @ObservationIgnored private var order: [String] = []
    /// Ids being written or queued right now, so a second row for the same conversation doesn't write again.
    @ObservationIgnored private var pending: Set<String> = []
    /// Ids the model gave no title for this session; not retried on every scroll.
    @ObservationIgnored private var failed: Set<String> = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiting: [(token: UUID, resume: CheckedContinuation<Bool, Never>)] = []

    init(writer: OnDeviceTextWriting, defaults: UserDefaults) {
        self.writer = writer
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([SavedTitle].self, from: data) {
            for entry in saved.suffix(Self.limit) where titles[entry.id] == nil {
                titles[entry.id] = entry.title
                order.append(entry.id)
            }
        }
    }

    /// Writes a title for conversation `id` unless one is known. Returns when done; the result shows
    /// through `titles`. A caller cancelled while queued gives up without writing.
    func resolve(id: String, title: String, snippet: String) async {
        guard !Task.isCancelled, titles[id] == nil, !failed.contains(id), !pending.contains(id),
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        guard await acquire() else { return }
        defer { release() }
        guard !Task.isCancelled else { return }
        let reply = await writer.write(
            instructions: Self.instructions,
            prompt: Self.prompt(title: title, snippet: snippet),
            timeout: Self.timeout)
        guard !Task.isCancelled else { return }
        if let reply, !reply.isEmpty {
            store(id, reply)
        } else {
            failed.insert(id)
        }
    }

    static func prompt(title: String, snippet: String) -> String {
        var text = "First message: \(OnDeviceText.truncate(title, to: 400))"
        if !snippet.isEmpty { text += "\nExcerpt: \(OnDeviceText.truncate(snippet, to: 300))" }
        return text
    }

    // MARK: Concurrency

    /// Takes a write slot, waiting in line when all are busy. False when cancelled while waiting.
    private func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if running < Self.maxConcurrent {
            running += 1
            return true
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
                // Runs synchronously on the main actor, so the cancel hop below always finds this entry.
                if Task.isCancelled {
                    resume.resume(returning: false)
                } else {
                    waiting.append((token, resume))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiting(token) }
        }
    }

    private func cancelWaiting(_ token: UUID) {
        guard let i = waiting.firstIndex(where: { $0.token == token }) else { return }
        waiting.remove(at: i).resume.resume(returning: false)
    }

    /// Hands the slot to the next waiter, or frees it.
    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().resume.resume(returning: true)
        }
    }

    // MARK: Cache

    private func store(_ id: String, _ title: String) {
        if titles[id] == nil { order.append(id) }
        titles[id] = title
        while order.count > Self.limit {
            titles[order.removeFirst()] = nil
        }
        let saved = order.compactMap { id in titles[id].map { SavedTitle(id: id, title: $0) } }
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}

private struct SavedTitle: Codable {
    let id: String
    let title: String
}
