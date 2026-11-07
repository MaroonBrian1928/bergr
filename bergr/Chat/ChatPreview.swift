#if DEBUG
import HerdrKit
import SwiftUI
import UIKit

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
            // `-bergr.chatPreviewShort YES`: a conversation shorter than the screen.
            if UserDefaults.standard.bool(forKey: "bergr.chatPreviewShort") {
                feed.loadItems(Array(feed.items.prefix(2)))
            }
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

extension ChatFeed {
    func loadSample() {
        let events: [[String: Any]] = [
            ["t": "msg", "id": "u1", "role": "user", "text": "Which services are running on each server? Put it in a table."],
            ["t": "tool", "id": "t1", "name": "Bash", "summary": "List services on alpha"],
            ["t": "tool", "id": "t2", "name": "Bash", "summary": "List services on beta"],
            ["t": "tool", "id": "t3", "name": "Read", "summary": "deploy/servers.toml"],
            ["t": "msg", "id": "a1", "role": "assistant", "text": """
            Here is what runs on each server:

            | Server | Service | Port |
            |---|---|---|
            | alpha | `api` | `8080` |
            | beta | `worker` | `9090` |
            | gamma | `cache` | `6379` |

            - **What's listed:** only the app's own services. I left out system ones like `sshd`.
            - **delta:** it timed out, so it is probably asleep. Wake it and run `app server start` there.
            """],
            ["t": "msg", "id": "u2", "role": "user", "text": "ok wake it and check again"],
            ["t": "tool", "id": "t4", "name": "Bash", "summary": "ssh delta 'systemctl list-units --type=service'"],
            ["t": "msg", "id": "a2", "role": "assistant", "text": "## delta\n\nIt's awake now. One service:\n\n```sh\napi.service  loaded active running  API server\n```\n\n> Its app server still needs starting before I can move the jobs."],
        ]
        loadEvents(events + [["t": "usage", "model": "claude-opus-5-5", "used": 70_512, "limit": 200_000]])
        loadItems(items + [
            Item(id: "p1", kind: .plan([
                PlanStep(text: "Check the services on each server", status: "completed"),
                PlanStep(text: "Start the app server on delta", status: "in_progress"),
                PlanStep(text: "Move the jobs over", status: "pending"),
            ])),
            Item(id: "i1", kind: .image(data: Self.sampleImage(), fromUser: false)),
            Item(id: "q1", kind: .question(title: "What should I do with the jobs on delta?",
                                           options: ["Move them now", "Wait for the app server", "Leave them"])),
        ])
    }

    /// A small picture drawn in code, for the image bubble.
    private static func sampleImage() -> Data {
        let size = CGSize(width: 240, height: 160)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1),
                          UIColor(red: 0.36, green: 0.42, blue: 0.62, alpha: 1)].map(\.cgColor)
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                      locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            UIBezierPath(ovalIn: CGRect(x: 150, y: 28, width: 56, height: 56)).fill()
            UIColor.white.withAlphaComponent(0.6).setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 96, width: 120, height: 14), cornerRadius: 7).fill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 118, width: 80, height: 14), cornerRadius: 7).fill()
        }
        return image.pngData() ?? Data()
    }
}
#endif

#if DEBUG
/// A fake agent for the demo machine (`-bergr.demo YES -bergr.demoChat YES`): the real chat,
/// over a real (demo) terminal, with a conversation that answers what is sent to it.
extension ChatFeed {
    func runDemo() async {
        loadSample()
        applyDemo(["t": "usage", "model": "claude-opus-5-5", "used": 70_512, "limit": 200_000])
        // Stays "running" like a real feed, until the chat goes away.
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
    }

    /// The fake agent hears a reply: it shows up, a tool runs, then an answer comes.
    func demoUserSaid(_ text: String) {
        let n = items.count
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            demoWorking = true
            applyDemo(["t": "msg", "id": "demo-u\(n)", "role": "user", "text": text])
            try? await Task.sleep(for: .milliseconds(900))
            // Steps start one by one; output of the running one arrives, then grows.
            applyDemo(["t": "tool", "id": "demo-t\(n)a", "name": "Bash", "summary": "Check the deploy log\ntail -50 /var/log/deploy.log"])
            try? await Task.sleep(for: .milliseconds(800))
            applyDemo(["t": "toolout", "id": "demo-t\(n)a", "text": "14:01:58 building alpha\n14:02:01 building beta"])
            try? await Task.sleep(for: .milliseconds(800))
            applyDemo(["t": "toolout", "id": "demo-t\(n)a", "text": "14:01:58 building alpha\n14:02:01 building beta\n14:02:03 gamma skipped (pinned)\n14:02:04 deploy finished, 0 errors"])
            try? await Task.sleep(for: .milliseconds(700))
            // A sub-agent starts, works for about four seconds (its steps count up), and finishes.
            applyDemo(["t": "tool", "id": "demo-t\(n)s", "name": "Task", "summary": "Audit the pinned servers"])
            let sub = ["t": "subagent", "id": "demo-s\(n)", "parent": "demo-t\(n)s", "name": "Audit pins", "kind": "Explore"] as [String: Any]
            for (steps, said) in [(1, "Reading deploy/servers.toml"), (3, "Checking which servers are pinned"),
                                  (5, "Comparing pins with the builds")] {
                applyDemo(sub.merging(["state": "running", "steps": steps, "summary": said]) { $1 })
                try? await Task.sleep(for: .milliseconds(1300))
            }
            applyDemo(sub.merging(["state": "done", "steps": 6, "summary": "Only gamma is pinned, and it is stale"]) { $1 })
            try? await Task.sleep(for: .milliseconds(500))
            applyDemo(["t": "tool", "id": "demo-t\(n)b", "name": "Read", "summary": "deploy/servers.toml"])
            try? await Task.sleep(for: .milliseconds(900))
            applyDemo(["t": "toolout", "id": "demo-t\(n)b", "text": "[alpha]\nbuild = \"new\"\n[beta]\nbuild = \"new\"\n[gamma]\nbuild = \"old\"\npinned = true"])
            try? await Task.sleep(for: .milliseconds(700))
            applyDemo(["t": "tool", "id": "demo-t\(n)c", "name": "Bash", "summary": "Compare builds\nfor h in alpha beta gamma; do ssh $h app version; done"])
            try? await Task.sleep(for: .milliseconds(1100))
            applyDemo(["t": "toolout", "id": "demo-t\(n)c", "text": "alpha 2.4.1\nbeta 2.4.1\ngamma 2.3.9"])
            try? await Task.sleep(for: .milliseconds(1100))
            applyDemo(["t": "msg", "id": "demo-a\(n)", "role": "assistant", "text": """
            Here's what I found about **\(text.prefix(40))**:

            - The last deploy finished at 14:02 with no errors.
            - `alpha` and `beta` are on the new build, `2.4.1`; `gamma` is still on the old one, `2.3.9`, because it is pinned in `deploy/servers.toml`.

            The pin was added two weeks ago, probably to hold `gamma` back while the cache migration was running. That migration is done now, so the pin has no reason to stay, and keeping it means `gamma` slowly drifts away from the other two servers, which makes the next incident harder to reason about.

            ```sh
            deploy --only gamma
            ```

            Rolling it forward takes about a minute and does not drop connections, since the cache warms up before the old process exits. I would remove the pin in the same change so that the next deploy does not skip it again.

            Want me to roll `gamma` forward now?
            """])
            demoWorking = false
        }
    }
}
#endif
