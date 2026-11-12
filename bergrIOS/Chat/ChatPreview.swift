import HerdrKit
import SwiftUI
import UIKit

#if DEBUG
/// The chat with sample content and no machine behind it (`-bergr.chatPreview YES`).
struct ChatPreviewScreen: View {
    @State private var feed = ChatFeed()
    @State private var model = TerminalScreenModel(theme: TerminalTheme.current(.dark, light: "", dark: ""))

    var body: some View {
        if UserDefaults.standard.bool(forKey: "bergr.imageViewerPreview"), let image = Self.sampleImage {
            ImageViewer(image: image)
        } else {
            chat
        }
    }

    /// A wide sample picture, bigger than the screen, for the viewer preview.
    private static let sampleImage: UIImage? = {
        let size = CGSize(width: 1600, height: 1000)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.systemIndigo.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemOrange.setFill()
            for i in 0..<8 { ctx.fill(CGRect(x: CGFloat(i) * 200 + 20, y: 20, width: 160, height: 960)) }
            UIColor.white.setFill(); ctx.cgContext.fillEllipse(in: CGRect(x: 650, y: 350, width: 300, height: 300))
        }
    }()

    private var chat: some View {
        NavigationStack {
            ChatView(feed: feed, agent: .claude, terminal: nil, model: model,
                     previewWorking: UserDefaults.standard.bool(forKey: "bergr.chatPreviewWorking"))
                .navigationTitle("web-app")
                .navigationSubtitle("Claude")
                .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            feed.loadSample()
            if UserDefaults.standard.bool(forKey: "bergr.previewAsyncQuestion") {
                feed.loadItems([])
                feed.applyDemo(["t": "question", "id": "preview-question", "title": "Which file should I update?",
                                "options": [], "async": true, "group": "preview", "index": 0, "count": 1])
            }
            // `-bergr.chatPreviewShort YES`: a conversation shorter than the screen.
            if UserDefaults.standard.bool(forKey: "bergr.chatPreviewShort") {
                feed.loadItems(Array(feed.items.prefix(2)))
            }
        }
        // `-bergr.stress <turns>`: the stress conversation and its live updates, for profiling.
        .task {
            let turns = UserDefaults.standard.integer(forKey: "bergr.stress")
            if turns > 0 { await feed.runStress(turns: turns) }
        }
        // `-bergr.chatPreviewLive YES`: usage keeps arriving, as from a working Codex.
        .task {
            guard UserDefaults.standard.bool(forKey: "bergr.chatPreviewLive") else { return }
            var used = 70_000
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                used += 137
                feed.loadEvents(feed.items.isEmpty ? [] : [], keepItems: true,
                                extra: [["t": "usage", "model": "claude-opus-5-5", "used": used, "limit": 200_000]])
            }
        }
    }
}
#endif
