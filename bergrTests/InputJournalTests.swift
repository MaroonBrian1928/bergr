import Foundation
import Testing
@testable import bergr

struct InputJournalTests {
    private let t0 = ContinuousClock.now

    @Test func outputAfterWriteConfirmsEntry() {
        var journal = InputJournal()
        let seq = journal.sent(Data("a".utf8), at: t0)
        journal.written(seq)
        journal.outputArrived(at: t0 + .milliseconds(10))
        #expect(journal.pending.isEmpty)
        #expect(journal.ambiguous.isEmpty)
    }

    @Test func unwrittenEntryIsNotConfirmedByOutput() {
        var journal = InputJournal()
        _ = journal.sent(Data("a".utf8), at: t0)
        journal.outputArrived(at: t0 + .milliseconds(10))
        let count = journal.pending.count
        #expect(count == 1)
        #expect(journal.pending.first?.written == false)
    }

    @Test func outputBeforeSendDoesNotConfirm() {
        var journal = InputJournal()
        let seq = journal.sent(Data("a".utf8), at: t0 + .milliseconds(10))
        journal.written(seq)
        journal.outputArrived(at: t0 + .milliseconds(5))
        let count = journal.pending.count
        #expect(count == 1)
    }

    @Test func channelEndMovesPendingToAmbiguousInOrder() {
        var journal = InputJournal()
        let a = journal.sent(Data("a".utf8), at: t0)
        let b = journal.sent(Data("b".utf8), at: t0)
        _ = journal.sent(Data("c".utf8), at: t0)
        journal.written(a)
        journal.written(b)
        journal.channelEnded()
        let seqs = journal.ambiguous.map(\.seq)
        #expect(seqs == [1, 2, 3])
        #expect(journal.pending.isEmpty)
        #expect(journal.ambiguousCount == 3)
    }

    @Test func failedWriteGoesToAmbiguous() {
        var journal = InputJournal()
        let seq = journal.sent(Data("x".utf8), at: t0)
        journal.failed(seq)
        let pendingEmpty = journal.pending.isEmpty
        let ambiguousSeqs = journal.ambiguous.map(\.seq)
        #expect(pendingEmpty)
        #expect(ambiguousSeqs == [seq])
    }

    @Test func takeAmbiguousReturnsConcatenatedBytesAndClears() {
        var journal = InputJournal()
        let a = journal.sent(Data("ab".utf8), at: t0)
        let b = journal.sent(Data("cd".utf8), at: t0)
        journal.written(a)
        journal.written(b)
        journal.channelEnded()
        let taken = journal.takeAmbiguous()
        #expect(taken == Data("abcd".utf8))
        #expect(journal.ambiguous.isEmpty)
        #expect(journal.ambiguousCount == 0)
    }

    @Test func maxEntriesDropsOldestPending() {
        var journal = InputJournal()
        for _ in 0..<(InputJournal.maxEntries + 1) {
            _ = journal.sent(Data("k".utf8), at: t0)
        }
        let count = journal.pending.count
        let firstSeq = journal.pending.first?.seq
        #expect(count == InputJournal.maxEntries)
        #expect(firstSeq == 2)
    }

    @Test func maxEntriesDropsOldestAmbiguous() {
        var journal = InputJournal()
        for _ in 0..<(InputJournal.maxEntries + 1) {
            _ = journal.sent(Data("k".utf8), at: t0)
        }
        journal.channelEnded()
        let count = journal.ambiguousCount
        let firstSeq = journal.ambiguous.first?.seq
        #expect(count == InputJournal.maxEntries)
        #expect(firstSeq == 2)
    }

    private func preview(_ bytes: [UInt8]) -> String {
        var journal = InputJournal()
        let seq = journal.sent(Data(bytes), at: t0)
        journal.failed(seq)
        return journal.ambiguousPreview
    }

    @Test func previewShowsCarriageReturnAsReturnSymbol() {
        let result = preview([0x61, 0x0d])
        #expect(result == "a⏎")
    }

    @Test func previewShowsDeleteAsBackspaceSymbol() {
        let result = preview([0x7f])
        #expect(result == "⌫")
    }

    @Test func previewShowsControlCAsCaret() {
        let result = preview([0x03])
        #expect(result == "^C")
    }

    @Test func previewShowsEscapeSequenceAsSingleEscapeSymbol() {
        // ESC [ A (cursor up)
        let result = preview([0x1b, 0x5b, 0x41])
        #expect(result == "⎋")
    }

    @Test func previewCutsLongTextWithEllipsis() {
        let result = preview(Array(String(repeating: "x", count: 60).utf8))
        #expect(result == String(repeating: "x", count: 39) + "…")
        #expect(result.count == 40)
    }

    @Test func previewOfEmptyIsEmpty() {
        let result = InputJournal().ambiguousPreview
        #expect(result.isEmpty)
    }
}


struct InputJournalOrderTests {
    @Test func ambiguousStaysInTypingOrder() {
        var j = InputJournal()
        let t = ContinuousClock.now
        let a = j.sent(Data("a".utf8), at: t)
        let enter = j.sent(Data("\r".utf8), at: t + .milliseconds(1))
        j.written(a)
        j.failed(enter)
        j.channelEnded()
        let bytes = j.takeAmbiguous()
        #expect(bytes == Data("a\r".utf8))
    }

    @Test func echoBeforeTheWriteReturnsConfirms() {
        var j = InputJournal()
        let t = ContinuousClock.now
        let k = j.sent(Data("x".utf8), at: t)
        j.outputArrived(at: t + .milliseconds(5))
        j.written(k)
        j.channelEnded()
        let n = j.ambiguousCount
        #expect(n == 0)
    }

    @Test func leavingOnPurposeAsksNothing() {
        var j = InputJournal()
        let k = j.sent(Data("x".utf8), at: .now)
        j.written(k)
        j.forgetPending()
        j.channelEnded()
        let n = j.ambiguousCount
        #expect(n == 0)
    }
}
