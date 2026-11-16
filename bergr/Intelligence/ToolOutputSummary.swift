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
    /// Output requests are coalesced while in flight and become repeatable after failure.
    @ObservationIgnored private var outputInFlight: Set<String> = []
    /// Step requests are coalesced while in flight; stored summaries are the success cache.
    @ObservationIgnored private var stepsInFlight: Set<String> = []
    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private let gate = ConcurrencyGate(limit: concurrent)
    @ObservationIgnored private let stepsAttemptCount: Int
    @ObservationIgnored private let stepsRetryBackoff: Duration

    init(writer: OnDeviceTextWriting, store: URL? = nil,
         stepsAttemptCount: Int = 3, stepsRetryBackoff: Duration = .milliseconds(250)) {
        self.writer = writer
        self.store = store
        self.stepsAttemptCount = max(1, stepsAttemptCount)
        self.stepsRetryBackoff = stepsRetryBackoff
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

    /// Writes the summary for a finished tool, caching successes by id. Does nothing while the tool runs, when
    /// its output is short, or while a request for it is in flight.
    func request(id: String, finished: Bool, name: String, command: String, output: String) async {
        guard finished, Self.isLong(output), !outputInFlight.contains(id), summary(for: id) == nil else { return }
        outputInFlight.insert(id)
        // A row scrolled away cancels its request: forget it so it is asked again when it returns.
        guard await gate.acquire() else { outputInFlight.remove(id); return }
        let prompt = """
        Tool: \(name) \(OnDeviceText.truncate(command, to: 200))
        Its output, last lines:
        \(OnDeviceText.truncate(output, to: 1500))
        """
        let reply = await writer.write(instructions: Self.instructions, prompt: prompt, timeout: Self.timeout)
        await gate.release()
        outputInFlight.remove(id)
        if Task.isCancelled { return }
        if let reply, let line = OnDeviceText.clean(reply, maxCharacters: 120), !Self.echoesPrompt(line) {
            set(line, for: id)
        }
    }

    /// What a run of steps was for, as a phrase ("fix the padding and rerun the tests"): a run's
    /// line reads "Ran 2 commands to …". Failed writes can be retried on a later request.
    func requestSteps(id: String, titles: [String]) async {
        guard titles.count > 1, !stepsInFlight.contains(id), summary(for: id) == nil else { return }
        stepsInFlight.insert(id)
        guard await gate.acquire() else { stepsInFlight.remove(id); return }
        let prompt = "Commands:\n" + titles.suffix(20).map { "- " + OnDeviceText.truncate(Self.bare($0), to: 120) }.joined(separator: "\n")
        // Longer than an output summary's: nothing waits on it (the row shows the count meanwhile).
        var summary: String?
        var holdsGate = true
        for attempt in 0..<stepsAttemptCount {
            let reply = await writer.write(instructions: Self.stepsInstructions, prompt: prompt, timeout: .seconds(8))
            if Task.isCancelled { break }
            if let reply, let line = OnDeviceText.clean(reply, maxCharacters: 80), !Self.echoesPrompt(line) {
                summary = Self.gist(line)
                break
            }
            guard attempt + 1 < stepsAttemptCount else { break }
            await gate.release()
            holdsGate = false
            do { try await Task.sleep(for: stepsRetryBackoff) } catch { break }
            guard !Task.isCancelled, await gate.acquire() else { break }
            holdsGate = true
        }
        if holdsGate { await gate.release() }
        stepsInFlight.remove(id)
        if !Task.isCancelled, let summary { set(summary, for: id) }
    }

    /// "to fix the padding." → "Fix the padding": a row title. Only the first line (the model
    /// sometimes answers one line per step), and a long one is cut at a comma past six words.
    static func gist(_ line: String) -> String {
        var text = String(line.split(whereSeparator: \.isNewline).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        if text.lowercased().hasPrefix("to ") { text.removeFirst(3) }
        let words = text.split(separator: " ")
        if words.count > 8 {
            let clauses = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            text = clauses.first.map { $0.split(separator: " ").count <= 8 ? $0 : words.prefix(8).joined(separator: " ") }
                ?? text
        }
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// A step as the model reads it: "Ran /bin/zsh -lc 'rg x'" → "rg x". A bare command reads as
    /// a task to it; "Ran" and the shell wrapper made it answer "Ran command ran command".
    static func bare(_ title: String) -> String {
        var text = title
        if text.hasPrefix("Ran ") { text.removeFirst(4) }
        if let match = text.firstMatch(of: /^(?:\/[\w\/]+\/)?(?:ba|z)?sh\s+-l?c\s+(['"])(.*)\1\s*$/) {
            text = String(match.output.2)
        }
        return text
    }

    /// The model sometimes answers with the instructions' own words ("counts: 689, what failed:
    /// none"): such a line says nothing, so it isn't shown.
    static func echoesPrompt(_ line: String) -> Bool {
        let l = line.lowercased()
        return ["what failed:", "names that matter", "counts:", "steps:", "the result:"].contains(where: l.contains)
    }

    static let stepsInstructions = """
    A coding agent ran some steps (shell commands, or descriptions of them). Say in one line of at \
    most 6 words what they did together, as one task, starting with a verb. Examples: "Check the \
    deployed container", "Run tests and fix padding", "Search the bot code for choices". \
    One line only. No period, no quotes.
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
