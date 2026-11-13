import Foundation
import Testing
@testable import TerminalCore

@Test func searchFindsEveryMatchAcrossRowsCaseInsensitively() {
    let lines = ["Error: one", "nothing", "an ERROR and another error", ""]
    let found = TerminalSearch.matches(for: "error", in: lines)
    #expect(found == [
        .init(row: 0, start: 0, length: 5), .init(row: 2, start: 3, length: 5), .init(row: 2, start: 21, length: 5),
    ])
}

@Test func searchWithNoMatchOrBlankQueryFindsNothing() {
    #expect(TerminalSearch.matches(for: "zzz", in: ["abc"]).isEmpty)
    #expect(TerminalSearch.matches(for: "", in: ["abc"]).isEmpty)
}

@Test func matchStepWrapsAround() {
    #expect(TerminalSearch.step(from: nil, count: 3, forward: true) == 0)
    #expect(TerminalSearch.step(from: nil, count: 3, forward: false) == 2)
    #expect(TerminalSearch.step(from: 2, count: 3, forward: true) == 0)
    #expect(TerminalSearch.step(from: 0, count: 3, forward: false) == 2)
    #expect(TerminalSearch.step(from: 1, count: 3, forward: true) == 2)
    #expect(TerminalSearch.step(from: 0, count: 0, forward: true) == nil)
}

@Test func firstMatchStartsAtTheViewport() {
    let m = [TerminalSearch.Match(row: 1, start: 0, length: 1), .init(row: 5, start: 0, length: 1)]
    #expect(TerminalSearch.firstMatch(atOrAfter: 2, in: m) == 1)
    #expect(TerminalSearch.firstMatch(atOrAfter: 9, in: m) == 0)
}

@Test func columnsCountWideCharacters() {
    #expect(TerminalSearch.column(ofCharacter: 3, in: "a漢b needle") == 4)
}

@Test func promptHeuristic() {
    #expect(PromptDetector.looksLikePrompt("brian@mac:~/src$ ls"))
    #expect(PromptDetector.looksLikePrompt("~/src/bergr % git status"))
    #expect(PromptDetector.looksLikePrompt("bergr ❯ "))
    #expect(PromptDetector.looksLikePrompt("❯"))
    #expect(PromptDetector.looksLikePrompt("/tmp > ls"))
    #expect(!PromptDetector.looksLikePrompt("> quoted text"))
    #expect(!PromptDetector.looksLikePrompt("❯ 1. Yes"))
    #expect(!PromptDetector.looksLikePrompt("total 12"))
}

@Test func promptJumpsFindNeighbours() {
    let rows = [2, 10, 20]
    #expect(PromptDetector.jump(from: 10, rows: rows, forward: false) == 2)
    #expect(PromptDetector.jump(from: 10, rows: rows, forward: true) == 20)
    #expect(PromptDetector.jump(from: 20, rows: rows, forward: true) == nil)
    #expect(PromptDetector.jump(from: 2, rows: rows, forward: false) == nil)
}

@Test func markedPromptsWinOverTheHeuristic() {
    let lines = ["~/a % ls", "x", "plain"]
    #expect(PromptDetector.promptRows(lines: lines, marked: [2]) == [2])
    #expect(PromptDetector.promptRows(lines: lines, marked: []) == [0])
}

@Test func snapshotCoversScrollbackAndMarksOSC133() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 3)
    for i in 1...6 { vt.write(Data("line \(i)\r\n".utf8)) }
    vt.write(Data("\u{1b}]133;A\u{7}$ cmd".utf8))
    let snap = vt.textSnapshot()
    #expect(snap.lines.first == "line 1")
    #expect(snap.lines.contains("line 6"))
    #expect(snap.lines.last == "$ cmd")
    #expect(snap.markedPromptRows == [snap.lines.count - 1])
}

@Test func scrollToRowAndSelectHighlightsAMatch() throws {
    let vt = try VirtualTerminal(cols: 20, rows: 3)
    for i in 1...12 { vt.write(Data("line \(i)\r\n".utf8)) }
    let snap = vt.textSnapshot()
    let match = try #require(TerminalSearch.matches(for: "LINE 4", in: snap.lines).first)
    vt.scroll(toRow: match.row)
    #expect(vt.viewportTopRow == match.row)
    vt.select(row: match.row, columns: 0...5)
    #expect(vt.selectedText() == "line 4")
    #expect(vt.frame().text.hasPrefix("line 4"))
}
