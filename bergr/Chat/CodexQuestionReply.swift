import Foundation

/// Select the asynchronous question's composer before sending. An ordinary chat send can
/// queue a new instruction instead of answering the question Codex asked.
@MainActor enum CodexQuestionReply {
    /// The newest async Codex question still open: not answered in the transcript and not picked
    /// or being sent from the app. `items` are the chat's items as (id, title) for questions.
    static func open(items: [(String, String)?], info: (String) -> (async: Bool, answered: Bool)?,
                     picked: (String) -> Bool) -> (id: String, title: String)? {
        for item in items.reversed() {
            guard let (id, title) = item, let i = info(id), i.async else { continue }
            if i.answered || picked(id) { continue }
            return (id, title)
        }
        return nil
    }

    /// Whether a reply from the reply box should answer the open question: plain text only (no
    /// images, shell `!` or `/` commands), unless the user chose to send it as a new message.
    static func answersQuestion(text: String, hasImages: Bool, sendAsNew: Bool) -> Bool {
        !sendAsNew && !hasImages && !text.isEmpty && !text.hasPrefix("!") && !text.hasPrefix("/")
    }

    static func selected(title: String, lines: [String]) -> Bool {
        func normalized(_ text: String) -> String {
            text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let screen = normalized(lines.suffix(12).joined(separator: " "))
        guard let range = screen.range(of: "Re:", options: .backwards) else { return false }
        let prompt = normalized(title)
        guard !prompt.isEmpty else { return false }
        return screen[range.upperBound...].contains(String(prompt.prefix(60)))
    }

    static func send(_ answer: String, title: String, pendingCount: Int,
                     lines: () -> [String], previous: () -> Void,
                     paste: (String) -> Void, submit: () -> Void,
                     settle: Duration = .milliseconds(150),
                     selectionWait: Duration = .seconds(2)) async -> Bool {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        for step in 0...max(1, pendingCount) {
            guard !Task.isCancelled else { return false }
            if selected(title: title, lines: lines()) {
                paste(text)
                do { try await Task.sleep(for: settle) } catch { return false }
                submit()
                return true
            }
            if step < max(1, pendingCount) {
                let before = lines()
                previous()
                let end = ContinuousClock.now + selectionWait
                while !selected(title: title, lines: lines()), lines() == before, ContinuousClock.now < end {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
                }
            }
        }
        return false
    }
}
