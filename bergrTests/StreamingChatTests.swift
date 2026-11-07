import Foundation
import Testing
@testable import bergr

@MainActor
struct StreamingChatTests {
    @Test func revealFinishesWithinOneAndAHalfSeconds() {
        for words in [1, 10, 60, 67, 68, 200, 1000] {
            let d = RevealSchedule.duration(totalWords: words)
            #expect(d <= 1.5)
            #expect(RevealSchedule.revealedWords(elapsed: d, totalWords: words, reduceMotion: false) == words)
            #expect(RevealSchedule.revealedWords(elapsed: 1.5, totalWords: words, reduceMotion: false) == words)
        }
    }

    @Test func revealGrowsAndNeverExceeds() {
        var last = 0
        for step in 0...20 {
            let n = RevealSchedule.revealedWords(elapsed: Double(step) * 0.05, totalWords: 50, reduceMotion: false)
            #expect(n >= last && n <= 50)
            last = n
        }
        #expect(RevealSchedule.revealedWords(elapsed: 0, totalWords: 50, reduceMotion: false) < 50)
        // Short replies run at about 45 words a second.
        let half = RevealSchedule.revealedWords(elapsed: 0.5, totalWords: 100, reduceMotion: false)
        #expect(half > 30 && half < 100)
    }

    @Test func reduceMotionShowsAtOnce() {
        #expect(RevealSchedule.revealedWords(elapsed: 0, totalWords: 80, reduceMotion: true) == 80)
    }

    @Test func hidesWordsAfterTheRevealedOnes() {
        let text = AttributedString("one two three")
        let shown = text.revealing(words: 2)
        #expect(shown.runs.count == 2)
        #expect(String(shown.characters) == "one two three")
        #expect(text.revealing(words: 3).runs.count == 1)
    }

    @Test func wordCounts() {
        #expect(MarkdownBlock.paragraph("one **two** three").wordCount == 3)
        #expect(MarkdownBlock.code("a b\nc").wordCount == 3)
        #expect(MarkdownBlock.totalWords([.paragraph("a b"), .rule, .table([["x"]])]) == 4)
    }

    private func tool(_ id: String) -> ChatFeed.Item { .init(id: id, kind: .tool(name: "Bash", summary: "ls")) }
    private func said(_ id: String) -> ChatFeed.Item { .init(id: id, kind: .assistant(text: "hi", blocks: [])) }

    @Test func liveRunIsTheTrailingOneWhileWorking() {
        let items = [said("a"), tool("t1"), tool("t2")]
        #expect(LiveRun.id(items: items, working: true) == "tools-t1")
        #expect(LiveRun.id(items: items, working: false) == nil)
    }

    @Test func runEndsWhenTheAgentMovesOn() {
        #expect(LiveRun.id(items: [tool("t1"), said("a")], working: true) == nil)
        #expect(LiveRun.id(items: [], working: true) == nil)
    }

    @Test func toolOutputAttachesByIdAndLiveRepliesReveal() {
        let feed = ChatFeed()
        feed.loadItems([said("old")])
        feed.applyDemo(["t": "tool", "id": "t1", "name": "Bash", "summary": "ls"])
        feed.applyDemo(["t": "toolout", "id": "t1", "text": "a\nb"])
        #expect(feed.toolOutput["t1"] == "a\nb")
        #expect(feed.items.count == 2)
        feed.applyDemo(["t": "msg", "id": "new", "role": "assistant", "text": "hello there"])
        #expect(feed.revealStart["new"] != nil)
        #expect(feed.revealStart["old"] == nil)
    }

    @Test func backlogDoesNotReveal() {
        let feed = ChatFeed()
        feed.loadEvents([["t": "msg", "id": "a", "role": "assistant", "text": "earlier"]])
        #expect(feed.revealStart.isEmpty)
    }
}
