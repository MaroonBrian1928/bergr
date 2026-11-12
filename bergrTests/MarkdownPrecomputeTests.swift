import Foundation
import SwiftUI
import Testing
@testable import bergr

/// What a parsed block carries, so drawing it does no parsing or measuring.
struct MarkdownPrecomputeTests {
    @Test func blocksCarryParsedInlineTextAndWordCounts() {
        let blocks = MarkdownBlock.parse("## Title with *emphasis*\n\nSome **bold** and `code here` words.\n\n- item one two")
        #expect(blocks.count == 3)
        guard case .heading(_, let title) = blocks[0].kind, case .paragraph(let prose) = blocks[1].kind,
              case .bullet(_, _, let item) = blocks[2].kind else {
            Issue.record("unexpected block shapes: \(blocks)")
            return
        }
        #expect(title.words == 3)
        #expect(String(title.styled(.of(.light)).characters) == "Title with emphasis")
        #expect(prose.words == 6)
        #expect(String(prose.styled(.of(.dark)).characters).replacingOccurrences(of: "\u{00A0}", with: " ") == "Some bold and code here words.")
        #expect(item.words == 3)
        for block in blocks {
            #expect(block.wordCount == block.wordCountUncached)
        }
        #expect(MarkdownBlock.totalWords(blocks) == 12)
    }

    @Test func inlineTextIsParsedOncePerPalette() {
        let inline = MarkdownInline("a `x y` b")
        // Light and dark differ only in the code colors; the plain text is the same in both.
        #expect(String(inline.styled(.of(.light)).characters) == String(inline.styled(.of(.dark)).characters))
        #expect(inline == MarkdownInline("a `x y` b"))
    }

    @Test func codeBlockCarriesItsPreparedText() {
        let blocks = MarkdownBlock.parse("Run:\n```\nlet a = 1\nlet b = 2\n```")
        guard case .code(let code)? = blocks.last?.kind else {
            Issue.record("expected a trailing code block, got \(blocks)")
            return
        }
        // The view draws this text directly, wrapped, with no horizontal scroll view around it.
        #expect(String(code.attributed.characters) == "let a = 1\nlet b = 2")
        #expect(code.words == 8)
        let block = MarkdownBlock(.code(code))
        #expect(block.wordCount == block.wordCountUncached)
    }

    @Test func tableWidthsArePrecomputed() {
        let blocks = MarkdownBlock.parse("| a | longer header |\n|---|---|\n| x | yy |")
        guard case .table(let table)? = blocks.first?.kind else {
            Issue.record("expected a table, got \(blocks)")
            return
        }
        #expect(table.columns == 2)
        // The first column is at its 64 point minimum, the second is 13 characters at 7.5 points.
        #expect(table.widths == [64, 97.5])
        #expect(table.cells.count == 2)
        #expect(table.cells.allSatisfy { $0.count == 2 })
        #expect(String(table.cells[1][1].styled(.of(.light)).characters) == "yy")
    }

    @Test func tableWidthsClampAtTheMaximum() {
        let wide = String(repeating: "w", count: 60)
        let table = MarkdownTable([["h", wide]])
        #expect(table.widths == [64, 240])
    }

    @Test func ragedRowsArePaddedToTheWidestRow() {
        let table = MarkdownTable([["a", "b", "c"], ["d"]])
        #expect(table.columns == 3)
        #expect(table.cells[1].count == 3)
        #expect(String(table.cells[1][2].styled(.of(.light)).characters).isEmpty)
    }
}
