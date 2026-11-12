import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Short text written on the device by Apple's on-device model (Foundation Models). Nothing leaves
/// the device. Every caller has a plain fallback: this returns nil when Apple Intelligence is off,
/// the device doesn't support it, the model fails, or it takes longer than `timeout`.
nonisolated protocol OnDeviceTextWriting: Sendable {
    /// Nil when it can't: the caller shows its fallback.
    func write(instructions: String, prompt: String, timeout: Duration) async -> String?
}

enum OnDeviceText {
    /// The writer the app uses; tests pass a fake instead.
    static let shared: OnDeviceTextWriting = FoundationModelsWriter()

    /// Whether the model can run now (Apple Intelligence on, model ready).
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        #endif
        return false
    }

    /// Trims a reply to one paragraph of plain text: no surrounding quotes or markdown emphasis.
    static func clean(_ text: String, maxCharacters: Int = 240) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = s.split(separator: "\n", omittingEmptySubsequences: true).first { s = String(line) }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        if s.count >= 2, let f = s.first, let l = s.last, "\"'“”".contains(f), "\"'“”".contains(l) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return s.count > maxCharacters ? String(s.prefix(maxCharacters - 1)) + "…" : s
    }

    /// Text cut to `limit` characters, for building prompts (the model's context is small).
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

nonisolated struct FoundationModelsWriter: OnDeviceTextWriting {
    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                guard let reply = try? await session.respond(to: prompt) else { return nil }
                return OnDeviceText.clean(reply.content)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        #else
        return nil
        #endif
    }
}
