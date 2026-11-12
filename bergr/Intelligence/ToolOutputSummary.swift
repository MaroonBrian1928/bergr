import Foundation
import Observation

/// One-line summaries of finished tool runs whose output is long, written on the device. A row
/// shows its summary under its title; the full output stays one tap away. Without one (the model
/// is off, fails or is slow), the row shows just its title, as before.
@MainActor
@Observable
final class ToolOutputSummaries {
    static let shared = ToolOutputSummaries(writer: OnDeviceText.shared)

    /// Output longer than this many lines gets a summary.
    static let longerThanLines = 4
    /// Summaries being written at once; more wait their turn.
    static let concurrent = 3
    static let timeout: Duration = .seconds(3)

    /// The summary by tool id, once written.
    private(set) var lines: [String: String] = [:]
    /// Ids already asked for (answered or not): each tool is asked once.
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let writer: OnDeviceTextWriting
    @ObservationIgnored private let gate = ConcurrencyGate(limit: concurrent)

    init(writer: OnDeviceTextWriting) {
        self.writer = writer
    }

    func summary(for id: String) -> String? { lines[id] }

    /// Whether the output's tail is long enough to summarize (more than four lines of text).
    static func isLong(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n", omittingEmptySubsequences: false).count > longerThanLines
    }

    /// Writes the summary for a finished tool, once per id. Does nothing while the tool runs, when
    /// its output is short, or when it was asked before.
    func request(id: String, finished: Bool, name: String, command: String, output: String) async {
        guard finished, Self.isLong(output), !asked.contains(id) else { return }
        asked.insert(id)
        await gate.acquire()
        let prompt = """
        Tool: \(name) \(OnDeviceText.truncate(command, to: 200))
        Its output, last lines:
        \(OnDeviceText.truncate(output, to: 1500))
        """
        let reply = await writer.write(instructions: Self.instructions, prompt: prompt, timeout: Self.timeout)
        await gate.release()
        if let reply, let line = OnDeviceText.clean(reply, maxCharacters: 120) {
            lines[id] = line
        }
    }

    static let instructions = """
    You summarize the output of a tool a coding agent ran, in one plain line of at most 12 words. \
    Say the result: counts, what failed, names that matter. No markdown, no quotes, no preamble. \
    Reply with the line only.
    """
}

/// Lets at most `limit` holders in at once; the rest wait in order.
private actor ConcurrencyGate {
    private let limit: Int
    private var available: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
        available = limit
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            available = min(available + 1, limit)
        } else {
            waiting.removeFirst().resume()
        }
    }
}
