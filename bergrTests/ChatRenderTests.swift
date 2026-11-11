import Foundation
import SwiftUI
import Testing
import UIKit
@testable import bergr

/// What a live update rebuilds in the chat: a streamed token or a terminal frame must not redraw
/// the rows that didn't change.
@MainActor
@Suite(.serialized)
struct ChatRenderTests {
    static let prose = """
    Here is **what** I found in `Sources/App/Main.swift`:

    - the first thing, with some *emphasis* and a [link](https://example.com)
    - the second thing, a bit longer so that it wraps onto another line in a narrow window

    ```
    let a = 1
    let b = 2
    ```

    ## Next

    I will run the tests now and report back.
    """

    static func conversation(_ turns: Int) -> [ChatFeed.Item] {
        var items: [ChatFeed.Item] = []
        for i in 0..<turns {
            items.append(.init(id: "u\(i)", kind: .user("Question number \(i), please look into it")))
            items.append(.init(id: "t\(i)a", kind: .tool(name: "Bash", summary: "ls -la \(i)")))
            items.append(.init(id: "t\(i)b", kind: .tool(name: "Read", summary: "file\(i).swift")))
            let text = "Answer \(i). " + prose
            items.append(.init(id: "a\(i)", kind: .assistant(text: text, blocks: MarkdownBlock.parse(text))))
        }
        return items
    }

    struct Hosted {
        let window: UIWindow
        let feed: ChatFeed
        let model: TerminalScreenModel

        func flush() {
            window.rootViewController?.view.setNeedsLayout()
            window.layoutIfNeeded()
            CATransaction.flush()
        }

        func settle(_ seconds: Double = 0.05) async {
            flush()
            try? await Task.sleep(for: .seconds(seconds))
            flush()
        }
    }

    static func host(turns: Int, settle: Double = 0.5) async -> Hosted {
        let feed = ChatFeed()
        feed.loadItems(conversation(turns))
        let model = TerminalScreenModel(theme: TerminalTheme.all[0])
        let view = ChatView(feed: feed, agent: .claude, terminal: nil, model: model)
            .environment(KeyLibrary())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 900))
        window.rootViewController = UIHostingController(rootView: NavigationStack { view })
        window.makeKeyAndVisible()
        let hosted = Hosted(window: window, feed: feed, model: model)
        await hosted.settle(settle)
        return hosted
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Streams a reply word by word into a conversation of `turns` turns: the time per word and
    /// the bodies evaluated.
    static func stream(turns: Int, tokens: Int = 30) async -> (ms: Double, counts: [String: Int]) {
        let hosted = await host(turns: turns)
        var text = "Streaming"
        hosted.feed.applyDemo(["t": "msg", "id": "live", "role": "assistant", "text": text])
        await hosted.settle(2.5)  // the new row's reveal finishes
        RenderProbe.counts = [:]
        let clock = ContinuousClock()
        var spent = Duration.zero
        for i in 0..<tokens {
            text += " word\(i)"
            spent += clock.measure {
                hosted.feed.applyDemo(["t": "msg", "id": "live", "role": "assistant", "text": text])
                hosted.flush()
            }
            await hosted.settle(0.01)
        }
        hosted.window.isHidden = true
        return (ms(spent) / Double(tokens), RenderProbe.counts)
    }

    @Test func streamedTokenRebuildsOnlyItsRow() async {
        let tokens = 30
        let (ms, counts) = await Self.stream(turns: 60, tokens: tokens)
        print("PERF streamedToken turns=60 ms/token=\(ms) counts=\(counts)")
        // One message changed: only its markdown is rebuilt, each token.
        #expect(counts["MarkdownView", default: 0] <= tokens * 2)
        #expect(counts["UserBubble", default: 0] == 0)
        #expect(counts["ToolRun", default: 0] == 0)
    }

    /// Right after the chat opens, when SwiftUI can't yet compare the rows' values field by field
    /// (it works that out in the background, over seconds): anything that runs the chat's body
    /// still builds no row.
    @Test func chatBodyBuildsNoRowsRightAfterOpening() async {
        let hosted = await Self.host(turns: 60, settle: 0.05)
        RenderProbe.counts = [:]
        let clock = ContinuousClock()
        var spent = Duration.zero
        let updates = 20
        for i in 0..<updates {
            spent += clock.measure {
                hosted.feed.chosenEffort = "effort \(i)"
                hosted.flush()
            }
            await hosted.settle(0.01)
        }
        let counts = RenderProbe.counts
        print("PERF bodyOnly ms/update=\(Self.ms(spent) / Double(updates)) counts=\(counts)")
        hosted.window.isHidden = true
        #expect(counts["ChatView", default: 0] >= updates)
        #expect(counts["MarkdownView", default: 0] == 0)
        #expect(counts["UserBubble", default: 0] == 0)
        #expect(counts["ToolRun", default: 0] == 0)
    }

    @Test func toolOutputRebuildsOnlyItsRun() async {
        let hosted = await Self.host(turns: 60)
        RenderProbe.counts = [:]
        let lines = 20
        for i in 0..<lines {
            hosted.feed.applyDemo(["t": "toolout", "id": "t59b", "text": "line \(i)"])
            await hosted.settle(0.01)
        }
        let counts = RenderProbe.counts
        print("PERF toolOutput counts=\(counts)")
        hosted.window.isHidden = true
        #expect(counts["ToolRun", default: 0] <= lines * 2)
        #expect(counts["ToolRun", default: 0] >= 1)
        #expect(counts["MarkdownView", default: 0] == 0)
        #expect(counts["UserBubble", default: 0] == 0)
    }

    @Test func terminalFrameDoesNotRebuildTheChat() async {
        let hosted = await Self.host(turns: 10)
        hosted.model.showText(["working… 1s", "  accept edits on"])
        await hosted.settle(0.2)
        RenderProbe.counts = [:]
        for second in 2..<12 {
            hosted.model.showText(["working… \(second)s", "  accept edits on"])
            await hosted.settle(0.01)
        }
        let counts = RenderProbe.counts
        print("PERF terminalFrame counts=\(counts)")
        hosted.window.isHidden = true
        // Only the small views that show something from the screen read it.
        #expect(counts["ChatView", default: 0] == 0)
        #expect(counts["MarkdownView", default: 0] == 0)
        #expect(counts["MoreMenuSlot", default: 0] >= 10)
    }

    static func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        for child in view.subviews {
            if let found = scrollView(in: child) { return found }
        }
        return nil
    }

    @Test func scrollingRebuildsNothing() async throws {
        let hosted = await Self.host(turns: 60)
        let scroll = try #require(Self.scrollView(in: hosted.window))
        let bottom = scroll.contentSize.height - scroll.bounds.height
        scroll.contentOffset.y = bottom
        await hosted.settle(0.3)
        RenderProbe.counts = [:]
        let clock = ContinuousClock()
        var spent = Duration.zero
        let steps = 40
        for step in 1...steps {
            spent += clock.measure {
                scroll.contentOffset.y = bottom - CGFloat(step) * 60
                hosted.flush()
            }
            await hosted.settle(0.01)
        }
        let counts = RenderProbe.counts
        print("PERF scroll ms/step=\(Self.ms(spent) / Double(steps)) counts=\(counts) height=\(scroll.contentSize.height)")
        hosted.window.isHidden = true
        // Leaving the latest message shows the jump button (the chat's body runs for that, a few
        // times in all); no row is built again for it.
        #expect(counts["ChatView", default: 0] <= 4)
        #expect(counts["MarkdownView", default: 0] == 0)
        #expect(counts["UserBubble", default: 0] == 0)
        #expect(counts["ToolRun", default: 0] == 0)
    }
}
