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

    /// Trims a reply to one paragraph of plain text: no surrounding quotes, markdown emphasis or
    /// "Title:"/"Summary:" label. Nil when empty or when the model refused instead of answering.
    static func clean(_ text: String, maxCharacters: Int = 240) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let line = s.split(separator: "\n", omittingEmptySubsequences: true).first { s = String(line) }
        s = s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        s = s.trimmingCharacters(in: .whitespaces)
        for label in ["title:", "summary:"] where s.lowercased().hasPrefix(label) {
            s = String(s.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        if s.count >= 2, let f = s.first, let l = s.last, "\"'“”".contains(f), "\"'“”".contains(l) {
            s = String(s.dropFirst().dropLast())
        }
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !isRefusal(s) else { return nil }
        return s.count > maxCharacters ? String(s.prefix(maxCharacters - 1)) + "…" : s
    }

    /// Whether a reply is the model declining ("I'm sorry, but I can't…") rather than an answer.
    /// The on-device model often refuses in plain text instead of throwing.
    static func isRefusal(_ text: String) -> Bool {
        let s = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”*_")))
            .replacingOccurrences(of: "’", with: "'").lowercased()
        let openings = ["i'm sorry", "i am sorry", "sorry,", "sorry ", "i apologize", "i can't", "i cannot", "i can not",
                        "i'm unable", "i am unable", "i'm not able", "i am not able", "as an ai", "as a language model",
                        "unfortunately, i", "i won't", "i will not"]
        return openings.contains { s.hasPrefix($0) }
    }

    /// A reply usable as a conversation title: clean, not a refusal, at most 7 words, not a question.
    static func title(_ text: String) -> String? {
        guard let s = clean(text, maxCharacters: 80) else { return nil }
        guard s.split(whereSeparator: \.isWhitespace).count <= 7, !s.hasSuffix("?") else { return nil }
        return s
    }

    /// Runs `work`, returning nil at `timeout` even when the work ignores cancellation (a task
    /// group would wait for it). On timeout or caller cancellation the work is cancelled, not awaited.
    static func race<T: Sendable>(timeout: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
        let once = ResumeOnce<T?>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                once.set(continuation)
                let task = Task { once.finish(await work()) }
                once.onFinish { task.cancel() }
                Task {
                    try? await Task.sleep(for: timeout)
                    once.finish(nil)
                }
            }
        } onCancel: {
            once.finish(nil)
        }
    }

    /// Text cut to `limit` characters, for building prompts (the model's context is small).
    static func truncate(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

nonisolated struct FoundationModelsWriter: OnDeviceTextWriting {
    /// List-producing callers parse their own lines; summaries keep the one-paragraph default.
    var preserveLines = false

    static func usable(_ text: String, preserveLines: Bool) -> String? {
        if !preserveLines { return OnDeviceText.clean(text) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || OnDeviceText.isRefusal(trimmed) ? nil : trimmed
    }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let preserveLines = preserveLines
        return await OnDeviceText.race(timeout: timeout) {
            let session = LanguageModelSession(instructions: instructions)
            guard let reply = try? await session.respond(to: prompt) else { return nil }
            return Self.usable(reply.content, preserveLines: preserveLines)
        }
        #else
        return nil
        #endif
    }
}

/// Resumes a continuation once, with whichever value arrives first (work, timeout or cancel).
/// A value that arrives before the continuation is set is held until it is.
nonisolated private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?
    private var result: T?
    private var done = false
    private var finished: (@Sendable () -> Void)?

    func set(_ c: CheckedContinuation<T, Never>) {
        let ready: T? = lock.withLock {
            if done { return result }
            continuation = c
            return nil
        }
        if let ready { c.resume(returning: ready) }
    }

    /// Runs `action` when finished (now, if already).
    func onFinish(_ action: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if done { return true }
            finished = action
            return false
        }
        if now { action() }
    }

    func finish(_ value: T) {
        let (c, action): (CheckedContinuation<T, Never>?, (@Sendable () -> Void)?) = lock.withLock {
            if done { return (nil, nil) }
            done = true
            result = value
            defer { continuation = nil; finished = nil }
            return (continuation, finished)
        }
        c?.resume(returning: value)
        action?()
    }
}
