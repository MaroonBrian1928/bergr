import Foundation
import Observation
import SwiftUI

/// One-line summaries of finished tool runs whose output is long, written on the device. A row
/// shows its summary under its title; the full output stays one tap away. Without one (the model
/// is off, fails or is slow), the row shows just its title, as before.
@MainActor
@Observable
final class ToolOutputSummaries {
    static let shared = ToolOutputSummaries(writer: OnDeviceText.shared, store: storeURL)

    /// Written summaries kept across launches (Caches; the newest `kept`), so reopening a chat
    /// shows them at once instead of writing them again and swapping them in.
    static let storeURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("tool-summaries.json")
    static let kept = 2000

    /// Output longer than this many lines gets a summary.
    static let longerThanLines = 4
    /// Summaries being written at once; more wait their turn.
    static let concurrent = 3
    static let timeout: Duration = .seconds(3)

    /// One summary's slot: a row reading it redraws when that summary is written, not when any is.
    @MainActor @Observable final class Slot { fileprivate(set) var text: String? }
    /// The slots by id, created on first read. Not observed as a whole: writing one summary used to
    /// redraw every tool row in the chat.
    @ObservationIgnored private var slots: [String: Slot] = [:]

    private func slot(_ id: String) -> Slot {
        if let slot = slots[id] { return slot }
        let slot = Slot()
        slot.text = stored[id]
        slots[id] = slot
        return slot
    }

    @ObservationIgnored private let store: URL?
    /// What's saved: by id, and the ids oldest first (to drop the oldest past `kept`).
    @ObservationIgnored private var stored: [String: String] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var saving: Task<Void, Never>?

    private struct Saved: Codable { var id: String; var text: String }

    /// Sets a summary that was just written. Animated: the row grows into its second line
    /// instead of jumping (only the first time; after that it comes from the store).
    private func set(_ text: String, for id: String) {
        withAnimation(.smooth(duration: 0.35)) { slot(id).text = text }
        guard store != nil else { return }
        if stored[id] == nil { order.append(id) }
        stored[id] = text
        if order.count > Self.kept {
            for old in order.prefix(order.count - Self.kept) { stored[old] = nil }
            order.removeFirst(order.count - Self.kept)
        }
        saving?.cancel()
        saving = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let saved = self.order.compactMap { id in self.stored[id].map { Saved(id: id, text: $0) } }
            let data = try? JSONEncoder().encode(saved)
            Task.detached { try? data?.write(to: store, options: .atomic) }
        }
    }
    /// Ids already asked for (answered or not): each tool is asked once.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private let gate = ConcurrencyGate(limit: concurrent)

    init(writer: OnDeviceTextWriting, store: URL? = nil) {
        self.writer = writer
        self.store = store
        if let store, let data = try? Data(contentsOf: store),
           let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            for entry in saved.suffix(Self.kept) where stored[entry.id] == nil {
                stored[entry.id] = entry.text
                order.append(entry.id)
            }
        }
    }

    func summary(for id: String) -> String? { slot(id).text }

    /// Whether the output's tail is long enough to summarize (more than four lines of text).
    static func isLong(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n", omittingEmptySubsequences: false).count > longerThanLines
    }

    /// Writes the summary for a finished tool, once per id. Does nothing while the tool runs, when
    /// its output is short, or when it was asked before.
    func request(id: String, finished: Bool, name: String, command: String, output: String) async {
        guard finished, Self.isLong(output), !asked.contains(id), stored[id] == nil else { return }
        asked.insert(id)
        // A row scrolled away cancels its request: forget it so it is asked again when it returns.
        guard await gate.acquire() else { asked.remove(id); return }
        let prompt = """
        Tool: \(name) \(OnDeviceText.truncate(command, to: 200))
        Its output, last lines:
        \(OnDeviceText.truncate(output, to: 1500))
        """
        let reply = await writer.write(instructions: Self.instructions, prompt: prompt, timeout: Self.timeout)
        await gate.release()
        if Task.isCancelled, reply == nil { asked.remove(id); return }
        if let reply, let line = OnDeviceText.clean(reply, maxCharacters: 120), !Self.echoesPrompt(line) {
            set(line, for: id)
        }
    }

    /// What a run of steps was for, as a phrase ("fix the padding and rerun the tests"): a run's
    /// line reads "Ran 2 commands to …". Asked once per `id`.
    func requestSteps(id: String, titles: [String]) async {
        guard titles.count > 1, !asked.contains(id), stored[id] == nil else { return }
        asked.insert(id)
        guard await gate.acquire() else { asked.remove(id); return }
        let prompt = "Steps:\n" + titles.suffix(20).map { "- " + OnDeviceText.truncate($0, to: 120) }.joined(separator: "\n")
        let reply = await writer.write(instructions: Self.stepsInstructions, prompt: prompt, timeout: Self.timeout)
        await gate.release()
        if Task.isCancelled, reply == nil { asked.remove(id); return }
        if let reply, let line = OnDeviceText.clean(reply, maxCharacters: 80), !Self.echoesPrompt(line) {
            set(Self.gist(line), for: id)
        }
    }

    /// "to fix the padding." → "Fix the padding": a row title.
    static func gist(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        if text.lowercased().hasPrefix("to ") { text.removeFirst(3) }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// The model sometimes answers with the instructions' own words ("counts: 689, what failed:
    /// none"): such a line says nothing, so it isn't shown.
    static func echoesPrompt(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["what failed:", "names that matter", "counts:", "steps:", "the result:"].contains(where: l.contains)
    }

    static let stepsInstructions = """
    You name what a coding agent's steps did, from the list of steps, in at most 6 words, \
    starting with a verb, like "Fix padding and rerun tests" or "Find where usage is shown". \
    No period, no markdown, no quotes. Reply with the words only.
    """

    /// Requests waiting for a slot (for tests).
    var waitingCount: Int { get async { await gate.waitingCount } }

    static let instructions = """
    You summarize the output of a tool a coding agent ran, in one plain sentence of at most 12 \
    words, like "689 tests passed, none failed" or "Build failed in ChatView.swift". \
    Give numbers and file names when the output has them. No labels, no markdown, no quotes. \
    Reply with the sentence only.
    """
}

/// Lets at most `limit` holders in at once; the rest wait in order. A waiter cancelled while
/// queued leaves the line and gets false.
private actor ConcurrencyGate {
    private let limit: Int
    private var available: Int
    private var waiting: [(token: UUID, resume: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int) {
        self.limit = limit
        available = limit
    }

    var waitingCount: Int { waiting.count }

    /// False when cancelled before getting a slot (no slot is held then).
    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        if available > 0 {
            available -= 1
            return true
        }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    resume.resume(returning: false)
                } else {
                    waiting.append((token, resume))
                }
            }
        } onCancel: {
            Task { await self.cancel(token) }
        }
    }

    private func cancel(_ token: UUID) {
        guard let i = waiting.firstIndex(where: { $0.token == token }) else { return }
        waiting.remove(at: i).resume.resume(returning: false)
    }

    func release() {
        if waiting.isEmpty {
            available = min(available + 1, limit)
        } else {
            waiting.removeFirst().resume.resume(returning: true)
        }
    }
}
