import Foundation

/// Select the asynchronous question's composer before sending. An ordinary chat send can
/// queue a new instruction instead of answering the question Codex asked.
@MainActor enum CodexQuestionReply {
    /// The newest async Codex question still open: not answered in the transcript and not picked
    /// or being sent from the app. `items` are the chat's items as (id, title) for questions.
    /// `lastUserMessage` is the index in `items` of the user's newest message: a question before it
    /// counts as answered, even when the transcript's reply couldn't be matched to it (the feed
    /// restarted, say), so the reply box stops offering to answer it.
    static func open(items: [(String, String)?], info: (String) -> (async: Bool, answered: Bool)?,
                     picked: (String) -> Bool, lastUserMessage: Int? = nil) -> (id: String, title: String)? {
        for (index, item) in items.enumerated().reversed() {
            if let lastUserMessage, index < lastUserMessage { break }
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

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Panel: Equatable {
        let heading: String
        let options: [Int: String]
    }

    /// Only inspect the active panel immediately above its footer, never transcript history.
    private static func panel(lines: [String]) -> Panel? {
        guard let footer = lines.lastIndex(where: {
            let line = normalized($0).lowercased()
            return line.contains("enter submit") && line.contains("skip") && line.contains("main prompt")
        }) else { return nil }
        guard lines[(footer + 1)...].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
        let row = try! NSRegularExpression(pattern: #"^\s*[›>]?\s*([1-9])\.\s+(.+?)\s*$"#)
        var starts: [(Int, Int, String)] = []
        for i in 0..<footer {
            let line = lines[i]
            let range = NSRange(line.startIndex..., in: line)
            guard let match = row.firstMatch(in: line, range: range),
                  let numberRange = Range(match.range(at: 1), in: line),
                  let labelRange = Range(match.range(at: 2), in: line),
                  let number = Int(line[numberRange]) else { continue }
            starts.append((i, number, String(line[labelRange])))
        }
        guard let first = starts.lastIndex(where: { $0.1 == 1 }) else { return nil }
        let rows = Array(starts[first...])
        guard rows.count >= 2, rows.enumerated().allSatisfy({ $0.element.1 == $0.offset + 1 }) else { return nil }
        let firstLine = rows[0].0
        var headingStart = firstLine
        while headingStart > 0 && lines[headingStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            headingStart -= 1
        }
        let headingEnd = headingStart
        while headingStart > 0 && !lines[headingStart - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            headingStart -= 1
        }
        let heading = normalized(lines[headingStart..<headingEnd].joined(separator: " "))
        guard !heading.isEmpty else { return nil }
        var options: [Int: String] = [:]
        for (offset, entry) in rows.enumerated() {
            let end = offset + 1 < rows.count ? rows[offset + 1].0 : footer
            var label = entry.2
            if entry.0 + 1 < end {
                for line in lines[(entry.0 + 1)..<end] {
                    let part = line.trimmingCharacters(in: .whitespaces)
                    if !part.isEmpty { label += " " + part }
                }
            }
            options[entry.1] = normalized(label)
        }
        return Panel(heading: heading, options: options)
    }

    enum Result { case sent, notSent, unconfirmed }

    static func sendResult(_ answer: String, title: String, pendingCount: Int,
                     lines: () -> [String], previous: () async -> Void,
                     paste: (String) async -> Void, submit: () async -> Void,
                     choose: ((Int) async -> Void)? = nil,
                     confirmed: () -> Bool = { false },
                     settle: Duration = .milliseconds(150),
                     selectionWait: Duration = .seconds(2)) async -> Result {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notSent }
        let expected = normalized(title)
        guard !expected.isEmpty else { return .notSent }
        for step in 0...max(1, pendingCount) {
            guard !Task.isCancelled else { return .notSent }
            let current = lines()
            if let currentPanel = panel(lines: current) {
                if currentPanel.heading == expected,
                   let index = currentPanel.options.first(where: { $0.value == normalized(text) })?.key,
                   let choose {
                    await choose(index)
                    let end = ContinuousClock.now + selectionWait
                    repeat {
                        guard !Task.isCancelled else { return .unconfirmed }
                        if confirmed() { return .sent }
                        if let next = panel(lines: lines()), next.heading != currentPanel.heading { return .sent }
                        guard ContinuousClock.now < end else { break }
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return .unconfirmed }
                    } while true
                    return .unconfirmed
                }
                // An unmatched answer or another question must never receive text here.
                if currentPanel.heading == expected { return .notSent }
            } else if selected(title: title, lines: current) {
                await paste(text)
                do { try await Task.sleep(for: settle) } catch { return .notSent }
                await submit()
                return .sent
            }
            if step < max(1, pendingCount) {
                await previous()
                let end = ContinuousClock.now + selectionWait
                while ContinuousClock.now < end {
                    guard !Task.isCancelled else { return .notSent }
                    let current = lines()
                    if let panel = panel(lines: current), panel.heading == expected { break }
                    if panel(lines: current) == nil && selected(title: title, lines: current) { break }
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return .notSent }
                }
            }
        }
        return .notSent
    }

    static func send(_ answer: String, title: String, pendingCount: Int,
                     lines: () -> [String], previous: () async -> Void,
                     paste: (String) async -> Void, submit: () async -> Void,
                     choose: ((Int) async -> Void)? = nil,
                     confirmed: () -> Bool = { false },
                     settle: Duration = .milliseconds(150),
                     selectionWait: Duration = .seconds(2)) async -> Bool {
        await sendResult(answer, title: title, pendingCount: pendingCount, lines: lines,
                         previous: previous, paste: paste, submit: submit, choose: choose, confirmed: confirmed,
                         settle: settle, selectionWait: selectionWait) == .sent
    }

}
