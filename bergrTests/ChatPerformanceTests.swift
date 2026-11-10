import Foundation
import SwiftUI
import Testing
@testable import bergr

struct ChatPerformanceTests {
    @Test func cachedWordCountsMatchUncached() {
        let blocks: [MarkdownBlock] = [
            .paragraph("Some **bold** and `code here` words"), .heading(level: 2, text: "A *title*"),
            .code("let a = 1\nlet b = 2"), .rule, .quote("quoted text"),
        ]
        for block in blocks {
            #expect(block.wordCount == block.wordCountUncached)
            #expect(block.wordCount == block.wordCountUncached)  // second call hits the cache
        }
        #expect(MarkdownBlock.totalWords(blocks) == blocks.reduce(0) { $0 + $1.wordCountUncached })
    }

    @Test func codeAndProseDoNotShareCacheEntries() {
        let text = "**a** b"
        #expect(MarkdownBlock.paragraph(text).wordCount == MarkdownBlock.paragraph(text).wordCountUncached)
        #expect(MarkdownBlock.code(text).wordCount == MarkdownBlock.code(text).wordCountUncached)
        #expect(MarkdownBlock.code("`x` `y z`").wordCount == 3)
    }

    @Test func cachedCommandsMatch() {
        let text = "Run:\n```\ngit push origin main\n```"
        #expect(Commands.cachedIn(text) == Commands.in(text))
        #expect(Commands.cachedIn(text) == Commands.in(text))
        let steps = [(name: "Bash", summary: "ls -la"), (name: "Read", summary: "a.txt")]
        #expect(Commands.cachedRan(steps) == Commands.ran(steps))
        #expect(Commands.cachedRan(steps) == Commands.ran(steps))
    }

    @Test func workingPoolMatchesFitting() {
        let pool = WorkingPool(width: 300, seed: 42)
        #expect(pool.phrases == WorkingRow.fitting(300))
        #expect(pool.order == WorkingRow.order(pool.phrases.count, seed: 42))
        #expect(pool.markOrder == WorkingRow.order(WorkingMark.count, seed: 43))
        #expect(Set(pool.order) == Set(0..<pool.phrases.count))
    }
}
