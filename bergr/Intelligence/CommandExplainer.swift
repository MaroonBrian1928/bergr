import Foundation

/// One line on what a dangerous command would do, written on the device. Only commands that
/// DangerousCommand flags get an explanation; the classification decides, not the model.
struct CommandExplainer: Sendable {
    static let instructions = """
        You explain one shell command that an AI coding agent wants to run, so a person can decide. \
        Describe concretely and neutrally what this exact command would do: what it deletes, changes, \
        overwrites or sends, and what it affects. Never say the command is safe, harmless or fine. \
        Answer with one sentence of at most 20 words, plain text, nothing before or after it.
        """
    static let timeout: Duration = .seconds(3)
    static let maxWords = 20
    /// The model's context is small; a long command is cut for the prompt.
    static let maxCommandCharacters = 600

    let writer: OnDeviceTextWriting

    /// The explanation, or nil: when the text isn't dangerous, the model can't answer within
    /// `timeout`, or its answer isn't usable. The caller then shows only the pattern's reason.
    func explain(_ text: String) async -> String? {
        guard DangerousCommand.check(text) != nil else { return nil }
        let command = OnDeviceText.truncate(text, to: Self.maxCommandCharacters)
        guard let reply = await writer.write(instructions: Self.instructions,
                                             prompt: "Command:\n\(command)",
                                             timeout: Self.timeout) else { return nil }
        return Self.usable(reply)
    }

    /// Nil for an empty reply, one longer than `maxWords`, or one that calls the command safe.
    static func usable(_ reply: String) -> String? {
        let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              line.split(whereSeparator: \.isWhitespace).count <= maxWords,
              !line.localizedCaseInsensitiveContains("safe") else { return nil }
        return line
    }
}
