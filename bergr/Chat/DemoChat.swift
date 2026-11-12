import HerdrKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The sample and demo conversations ship: the built-in demo machine (Try the Demo) shows
// its agents as chats, so the app can be tried, and reviewed, without a server.
extension ChatFeed {
    /// A sample conversation: Claude's is a website change, Codex's a database upgrade, so two
    /// panes side by side show two different agents.
    func loadSample(_ agent: ChatAgent = .claude) {
        if agent == .codex { loadCodexSample() } else { loadClaudeSample() }
    }

    private func loadClaudeSample() {
        let events: [[String: Any]] = [
            ["t": "msg", "id": "u1", "role": "user", "text": "The settings page ignores dark mode. Can you add a toggle?"],
            ["t": "tool", "id": "t1", "name": "Grep", "summary": "colorScheme in src/"],
            ["t": "toolout", "id": "t1", "text": "src/theme.ts:12\nsrc/pages/Settings.tsx:48"],
            ["t": "tool", "id": "t2", "name": "Read", "summary": "src/pages/Settings.tsx"],
            ["t": "msg", "id": "a1", "role": "assistant", "text": """
            Found it. `Settings.tsx` hard-codes light colors instead of reading the theme:

            | File | Problem |
            |---|---|
            | `Settings.tsx` | `#fff` background, `#222` text |
            | `Toggle.tsx` | no dark variant |
            | `theme.ts` | fine, already has both palettes |

            I'll switch both components to theme tokens and add a **System / Light / Dark** toggle at the top of the page.
            """],
            ["t": "msg", "id": "u2", "role": "user", "text": "sounds good, send me a screenshot when it's done"],
            ["t": "tool", "id": "t3", "name": "Edit", "summary": "src/pages/Settings.tsx"],
            ["t": "tool", "id": "t4", "name": "Edit", "summary": "src/components/Toggle.tsx"],
            ["t": "tool", "id": "t5", "name": "Bash", "summary": "Take a screenshot\nnpm run shot -- /settings --dark"],
            ["t": "msg", "id": "a2", "role": "assistant", "text": "Here it is in dark mode. Contrast passes for body text, but the muted labels are at **4.2:1**, just under the 4.5 target."],
        ]
        loadEvents(events + [["t": "usage", "model": "claude-opus-5-5", "used": 70_512, "limit": 200_000]])
        loadItems(items + [
            Item(id: "i1", kind: .image(data: Self.sampleImage(), fromUser: false)),
            Item(id: "q1", kind: .question(title: "How should I fix the muted labels?",
                                           options: ["Lighten them to pass 4.5:1", "Make them regular text", "Leave them"])),
        ])
    }

    private func loadMigrationSample() {
        let events: [[String: Any]] = [
            ["t": "msg", "id": "u1", "role": "user", "text": "Orders need a discount code. Add it to the database and the API."],
            ["t": "tool", "id": "t1", "name": "Read", "summary": "db/schema.sql"],
            ["t": "tool", "id": "t2", "name": "Write", "summary": "db/migrations/0042_order_discount_code.sql"],
            ["t": "toolout", "id": "t2", "text": "ALTER TABLE orders ADD COLUMN discount_code text;\nCREATE INDEX orders_discount_code ON orders (discount_code);"],
            ["t": "tool", "id": "t3", "name": "Edit", "summary": "src/routes/orders.ts"],
            ["t": "tool", "id": "t4", "name": "Bash", "summary": "npm test"],
            ["t": "toolout", "id": "t4", "text": "Tests  64 passed (64)"],
            ["t": "msg", "id": "a1", "role": "assistant", "text": """
            The API accepts a `discount_code` now and the tests pass. The migration adds one nullable \
            column and an index, so it's quick and safe on a live table:

            ```sql
            ALTER TABLE orders ADD COLUMN discount_code text;
            CREATE INDEX orders_discount_code ON orders (discount_code);
            ```

            Shall I run it against the staging database?
            """],
            ["t": "tool", "id": "t5", "name": "Bash", "summary": "npm run migrate"],
        ]
        loadEvents(events + [["t": "usage", "model": "claude-opus-5-5", "used": 38_904, "limit": 200_000]])
    }

    private func loadCodexSample() {
        let events: [[String: Any]] = [
            ["t": "msg", "id": "u1", "role": "user", "text": "Upgrade the staging database to Postgres 18 and make sure nothing breaks."],
            ["t": "tool", "id": "t1", "name": "shell", "summary": "Check the current version\npsql -c 'select version()'"],
            ["t": "toolout", "id": "t1", "text": "PostgreSQL 17.4 on x86_64-pc-linux-gnu"],
            ["t": "tool", "id": "t2", "name": "shell", "summary": "Dump before upgrading\npg_dumpall > /backups/pre-18.sql"],
            ["t": "tool", "id": "t3", "name": "shell", "summary": "pg_upgrade --check"],
            ["t": "toolout", "id": "t3", "text": "Checking cluster versions        ok\nChecking database connection     ok\nChecking for incompatible types  ok\n*Clusters are compatible*"],
            ["t": "tool", "id": "t4", "name": "shell", "summary": "Run the upgrade\npg_upgrade --link -b /usr/lib/postgresql/17/bin -B /usr/lib/postgresql/18/bin"],
            ["t": "tool", "id": "t5", "name": "shell", "summary": "Run the test suite\nmake test DB=staging"],
            ["t": "toolout", "id": "t5", "text": "212 passed, 0 failed in 48.1s"],
            ["t": "msg", "id": "a1", "role": "assistant", "text": """
            Staging is on **Postgres 18.1** and every check is green.

            ```sh
            $ psql -c 'show server_version'
             18.1
            ```

            - The upgrade used `--link`, so it took 40 seconds and no extra disk.
            - The dump from before is in `/backups/pre-18.sql` if we need to roll back.
            - All 212 tests pass against the new server.
            """],
            ["t": "msg", "id": "n1", "role": "note", "text": "Used memory: staging backups live in /backups, not the app volume"],
        ]
        loadEvents(events + [["t": "usage", "model": "gpt-6.1-sol", "used": 41_208, "limit": 272_000]])
        loadItems(items + [
            Item(id: "p1", kind: .plan([
                PlanStep(text: "Back up the staging cluster", status: "completed"),
                PlanStep(text: "Check compatibility and upgrade", status: "completed"),
                PlanStep(text: "Run the tests against Postgres 18", status: "completed"),
            ])),
        ])
    }

    /// A small picture drawn in code, for the image bubble.
    private static func sampleImage() -> Data {
        #if os(iOS)
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
        #else
        return Data()
        #endif
    }
}

/// A fake agent for the demo machine (`-bergr.demo YES -bergr.demoChat YES`): the real chat,
/// over a real (demo) terminal, with a conversation that answers what is sent to it.
extension ChatFeed {
    func runDemo(agent: ChatAgent = .claude, cwd: String = "") async {
        #if DEBUG
        let turns = UserDefaults.standard.integer(forKey: "bergr.stress")
        if turns > 0 { await runStress(turns: turns); return }
        #endif
        // The shop API's agent is the one waiting to run a migration: its own conversation.
        if agent == .claude, cwd.hasSuffix("shop-api") { loadMigrationSample() } else { loadSample(agent) }
        if agent == .claude {
            applyDemo(["t": "usage", "model": "claude-opus-5-5", "used": 70_512, "limit": 200_000])
        }
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

#if DEBUG
/// A long conversation that keeps getting live updates, for profiling scrolling and streaming:
/// `-bergr.demo YES -bergr.stress <turns>` (`-bergr.stressMode quiet` loads it and sends nothing, `working` only shows the agent working, `idle` streams without that; `-bergr.stressGap <ms>` is the time between updates).
extension ChatFeed {
    static let stressProse = """
    Here is **what** I found in `Sources/App/Main.swift`:

    - the first thing, with some *emphasis* and a [link](https://example.com)
    - the second thing, a bit longer so that it wraps onto another line in a narrow window

    ```
    let a = 1
    let b = 2
    ```

    | File | Problem |
    |---|---|
    | `Settings.swift` | hard-coded colors |
    | `Toggle.swift` | no dark variant |

    ## Next

    I will run the tests now and report back. The change is small, but it touches the theme, so \
    every screen that reads a color from it is checked again, in light and in dark.
    """

    static func stressConversation(_ turns: Int) -> [Item] {
        var items: [Item] = []
        for i in 0..<turns {
            items.append(Item(id: "u\(i)", kind: .user("Question number \(i), please look into it")))
            items.append(Item(id: "t\(i)a", kind: .tool(name: "Bash", summary: "List the files\nls -la \(i)")))
            items.append(Item(id: "t\(i)b", kind: .tool(name: "Read", summary: "file\(i).swift")))
            let text = "Answer \(i). " + stressProse
            items.append(Item(id: "a\(i)", kind: .assistant(text: text, blocks: MarkdownBlock.parse(text))))
        }
        return items
    }

    /// Live updates sent so far (the profiling report divides its time by them).
    static var stressEvents = 0

    func runStress(turns: Int) async {
        loadItems(Self.stressConversation(turns))
        applyDemo(["t": "usage", "model": "claude-opus-5-5", "used": 70_512, "limit": 200_000])
        let mode = UserDefaults.standard.string(forKey: "bergr.stressMode") ?? "stream"
        if mode == "quiet" || mode == "working" {
            demoWorking = mode == "working"
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(60)) }
            return
        }
        // "idle": the same updates, without the agent showing as working.
        let working = mode != "idle"
        let gap = UserDefaults.standard.integer(forKey: "bergr.stressGap")
        let pause = Duration.milliseconds(gap > 0 ? gap : 33)
        try? await Task.sleep(for: .seconds(3))
        let words = Self.stressProse.split(separator: " ", omittingEmptySubsequences: false)
        var n = 0
        var used = 70_512
        while !Task.isCancelled {
            n += 1
            demoWorking = working
            applyDemo(["t": "msg", "id": "su\(n)", "role": "user", "text": "Stress question \(n)"])
            try? await Task.sleep(for: .milliseconds(300))
            applyDemo(["t": "tool", "id": "st\(n)", "name": "Bash", "summary": "Run the tests\nmake test"])
            var out: [String] = []
            for line in 0..<20 {
                out.append("test \(line) passed in 0.\(line)s")
                applyDemo(["t": "toolout", "id": "st\(n)", "text": out.suffix(12).joined(separator: "\n")])
                Self.stressEvents += 1
                try? await Task.sleep(for: pause)
            }
            // A reply streamed word by word.
            var text = "Reply \(n)."
            for word in words {
                text += " " + word
                applyDemo(["t": "msg", "id": "sa\(n)", "role": "assistant", "text": text])
                Self.stressEvents += 1
                used += 7
                if used % 5 == 0 { applyDemo(["t": "usage", "model": "claude-opus-5-5", "used": used, "limit": 200_000]) }
                try? await Task.sleep(for: pause)
            }
            demoWorking = false
            try? await Task.sleep(for: .milliseconds(600))
        }
    }
}
#endif
