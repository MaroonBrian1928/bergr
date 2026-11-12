import Foundation
import Observation

/// Up to three short replies the user might send next, written on the device from the agent's
/// last message once its turn has finished. Tapping one only fills the reply field.
@MainActor
@Observable
final class ReplySuggestions {
    static let shared = ReplySuggestions(writer: OnDeviceText.shared)

    static let maxChips = 3
    static let maxWords = 6
    static let timeout: Duration = .seconds(3)

    /// The chips by the id of the assistant message they answer. Each message is asked once.
    private(set) var chips: [String: [String]] = [:]
    @ObservationIgnored private var asked: Set<String> = []
    @ObservationIgnored private let writer: OnDeviceTextWriting

    init(writer: OnDeviceTextWriting) {
        self.writer = writer
    }

    /// Writes the chips for an assistant message, once. Nothing while the agent works, and nothing
    /// when the model writes nothing usable (the reply bar then shows no chips).
    func request(messageID: String, text: String, working: Bool) async {
        guard !working, !asked.contains(messageID) else { return }
        asked.insert(messageID)
        let prompt = "The agent's last message:\n" + OnDeviceText.truncate(text, to: 2000)
        let reply = await writer.write(instructions: Self.instructions, prompt: prompt, timeout: Self.timeout)
        let found = reply.map(Self.parse) ?? []
        if !found.isEmpty { chips[messageID] = found }
    }

    /// The model's reply as chips: one per line, bullets and quotes removed, at most six words
    /// each, no repeats (ignoring case), at most three.
    static func parse(_ reply: String) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for raw in reply.split(whereSeparator: \.isNewline) {
            guard let line = chip(from: String(raw)) else { continue }
            guard seen.insert(line.lowercased()).inserted else { continue }
            out.append(line)
            if out.count == maxChips { break }
        }
        return out
    }

    private static func chip(from raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = s.first, "-*•".contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        } else {
            let digits = s.prefix { $0.isNumber }
            if !digits.isEmpty, let marker = s.dropFirst(digits.count).first, marker == "." || marker == ")" {
                s = String(s.dropFirst(digits.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”`*_ ")).trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.split(whereSeparator: \.isWhitespace).count <= maxWords else { return nil }
        return s
    }

    static let instructions = """
    You suggest what the user might reply to a coding agent's last message. Write up to three short \
    replies, one per line, each at most six words, as the user would type them (for example "Run the tests"). \
    No numbering, no quotes, no other text.
    """
}
