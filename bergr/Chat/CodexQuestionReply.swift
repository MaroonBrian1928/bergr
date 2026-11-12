import Foundation

/// Select the asynchronous question's composer before sending. An ordinary chat send can
/// queue a new instruction instead of answering the question Codex asked.
@MainActor enum CodexQuestionReply {
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
