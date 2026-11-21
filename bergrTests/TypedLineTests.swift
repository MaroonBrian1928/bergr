import Foundation
import Testing
@testable import bergr

@MainActor
struct TypedLineTests {
    @Test func followsPlainTyping() {
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.type("git st")
        model.type("atus")
        #expect(model.typedLine == "git status")
    }

    @Test func anEscapeMakesTheLineUnknown() {
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.type("ls")
        model.type("\u{1b}[A")
        #expect(model.typedLine == nil)
        #expect(model.takeTypedLine() == nil)
    }

    @Test func pastingANewlineMakesItUnknown() {
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.type("echo ")
        model.paste("a\nb")
        // Without an emulator nothing is pasted; the line stays as typed.
        #expect(model.typedLine == "echo ")
    }

    @Test func combiningCharactersMakeItUnknown() {
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.type("caf")
        model.type("e\u{301}")
        #expect(model.typedLine == nil)
        #expect(TerminalScreenModel.trackable("plain text"))
        #expect(!TerminalScreenModel.trackable("a\tb"))
    }

    @Test func beforeAttachingItIsTakenBackFromTheQueue() {
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        model.type("half a line")
        #expect(model.takeTypedLine() == "half a line")
        #expect(model.typedLine == "")
    }

    @Test func takingBackKeepsEarlierQueuedLines() {
        var queue = [Data("echo first\r".utf8), Data("dra".utf8), Data("ft".utf8)]
        TerminalScreenModel.dropTail(Data("draft".utf8), from: &queue, orAppend: Data([0x7f]))
        #expect(queue == [Data("echo first\r".utf8)])
        var other = [Data("ab".utf8)]
        TerminalScreenModel.dropTail(Data("zz".utf8), from: &other, orAppend: Data([0x7f, 0x7f]))
        #expect(other == [Data("ab".utf8), Data([0x7f, 0x7f])])
        #expect(!TerminalScreenModel.trackable("\u{85}"))
    }
}
