import HerdrKit
import SwiftUI
#if os(iOS)
import UIKit
#endif

// The demo machines' agents open as chats, so the app can be tried, reviewed and photographed
// without a server. Five conversations about a small shop, shaped like real Claude Code and Codex
// sessions: an ask, replies in markdown, runs of tool calls with their output, a plan, questions.
// Everything is fixed text: what the on-device model would write (tool summaries, reply
// suggestions) is seeded here too, so two runs look the same.

/// The demo's conversations and what goes with them.
enum DemoChat {
    typealias Event = [String: Any]

    /// One live update, after a pause.
    struct Timed {
        var wait: Duration
        var event: Event
    }

    /// What a conversation gains when its terminal's status reaches `beat` (a status title or
    /// message). `after` is the stage that comes before it; a chat opened late gets the earlier
    /// stages at once and plays only the current one.
    struct Stage {
        var beat: String
        var after: String?
        var events: [Timed]
    }

    struct Conversation {
        var backlog: [Event]
        var stages: [Stage] = []
        var usage: Event
        var commands: [Event]

        func stage(for status: TerminalStatus?) -> Stage? {
            guard let status else { return nil }
            return stages.first { $0.beat == status.msg || $0.beat == status.title }
        }

        /// The stages that lead to `stage`, first to last.
        func chain(before stage: Stage) -> [Stage] {
            var out: [Stage] = []
            var at = stage.after
            while let beat = at, let earlier = stages.first(where: { $0.beat == beat }) {
                out.insert(earlier, at: 0)
                at = earlier.after
            }
            return out
        }
    }

    /// Every id in a demo conversation starts with this: nothing is asked of the model for them.
    static let idPrefix = "demo-"
    static func isDemo(_ id: String) -> Bool { id.hasPrefix(idPrefix) || id.hasPrefix("steps|" + idPrefix) }

    /// Message times count back from the app's start, so the sideways drag shows a real afternoon.
    static let start = Date()
    static func at(_ minutesAgo: Double) -> Double { (start.timeIntervalSince1970 - minutesAgo * 60).rounded() }

    private static func user(_ id: String, _ minutesAgo: Double, _ text: String) -> Event {
        ["t": "msg", "id": idPrefix + id, "role": "user", "text": text, "at": at(minutesAgo)]
    }

    private static func agent(_ id: String, _ minutesAgo: Double, _ text: String) -> Event {
        ["t": "msg", "id": idPrefix + id, "role": "assistant", "text": text, "at": at(minutesAgo)]
    }

    private static func tool(_ id: String, _ name: String, _ summary: String) -> Event {
        ["t": "tool", "id": idPrefix + id, "name": name, "summary": summary]
    }

    private static func out(_ id: String, _ text: String, failed: Bool = false) -> Event {
        var event: Event = ["t": "toolout", "id": idPrefix + id, "text": text]
        if failed { event["failed"] = true }
        return event
    }

    private static func plan(_ steps: [(String, String)]) -> Event {
        ["t": "plan", "id": idPrefix + "plan", "steps": steps.map { ["text": $0.0, "status": $0.1] }]
    }

    private static func live(_ seconds: Double, _ event: Event) -> Timed {
        Timed(wait: .milliseconds(Int(seconds * 1000)), event: event)
    }

    // MARK: Conversations

    static func conversation(address: String, agent: ChatAgent) -> Conversation {
        switch address {
        case DemoBeat.websiteAgent: website
        case DemoBeat.totalsAgent: totals
        case DemoBeat.upgradeAgent: upgrade
        case DemoBeat.cacheAgent: cache
        case DemoBeat.flakyTestAgent: flakyTest
        // A terminal started in the demo: the sample of its kind.
        default: agent == .codex ? upgrade : website
        }
    }

    /// Claude Code on the website: a finished turn. A search, a plan, edits, a test run that fails,
    /// the fix, then tests, the diff and the build, each with its summary.
    static var website: Conversation {
        Conversation(backlog: [
            user("b-u1", 58, "Add a dark mode toggle to the header. It should follow the system setting by default."),
            agent("b-a1", 58, "I'll look at how the header and the theme are set up first."),
            tool("b-t1", "Grep", "prefers-color-scheme in src/"),
            out("b-t1", "No matches found"),
            tool("b-t2", "Read", "src/styles/theme.css"),
            tool("b-t3", "Read", "src/components/Header.tsx"),
            agent("b-a2", 56, """
            The colors already come from CSS variables in `theme.css`, but only a light set exists:

            | File | What it needs |
            |---|---|
            | `theme.css` | the same tokens for dark |
            | `Header.tsx` | the toggle button |
            | `ThemeToggle.tsx` | new: System, Light, Dark |

            I'll remember the choice in `localStorage` and fall back to the system setting.
            """),
            plan([("Add dark values for the theme tokens", "completed"), ("Build the ThemeToggle component", "completed"),
                  ("Put the toggle in the header", "completed"), ("Run the tests and the build", "completed")]),
            tool("b-t4", "Edit", "src/styles/theme.css"),
            tool("b-t5", "Write", "src/components/ThemeToggle.tsx"),
            tool("b-t6", "Edit", "src/components/Header.tsx"),
            tool("b-t7", "Bash", "Run the tests\nnpm test"),
            out("b-t7", """
             FAIL  src/components/Header.test.tsx
              ● Header › matches the snapshot
                - <nav class="header">
                + <nav class="header"><button aria-label="Theme">

             Test Files  1 failed | 7 passed (8)
                  Tests  1 failed | 47 passed (48)
            """, failed: true),
            tool("b-t8", "Bash", "Update the Header snapshot\nnpx vitest run Header -u"),
            out("b-t8", " Snapshots  1 updated\n Tests  9 passed (9)"),
            agent("b-a3", 21, "One test failed, and it's the expected one: the header's snapshot didn't have the new button yet. I updated the snapshot. Running everything again."),
            tool("b-t9", "Bash", "Run the tests\nnpm test"),
            out("b-t9", """
             ✓ src/theme/tokens.test.ts (6)
             ✓ src/components/ThemeToggle.test.tsx (9)
             ✓ src/components/Header.test.tsx (9)
             ✓ src/cart/total.test.ts (10)

             Test Files  8 passed (8)
                  Tests  48 passed (48)
               Duration  12.04s
            """),
            agent("b-a4", 19, "All 48 pass. Checking how big the change is."),
            tool("b-t10", "Bash", "Check what changed\ngit diff --stat"),
            out("b-t10", """
             src/components/Header.tsx        |  14 ++++++----
             src/components/ThemeToggle.tsx   |  58 ++++++++++++++++
             src/styles/buttons.css           |   8 ++--
             src/styles/cards.css             |   6 ++--
             src/styles/theme.css             |  41 ++++++++++-
             …
             20 files changed, 212 insertions(+), 61 deletions(-)
            """),
            agent("b-a5", 18, "20 files, most of them one-line swaps from fixed colors to tokens. Last, a production build."),
            tool("b-t11", "Bash", "Build the site\nnpm run build"),
            out("b-t11", """
            vite v7.1.2 building for production...
            ✓ 412 modules transformed.
            dist/assets/index-C3kq.css    31.82 kB │ gzip:  6.90 kB
            dist/assets/index-Bx7d.js    214.37 kB │ gzip: 68.11 kB
            ✓ built in 3.41s
            """),
            agent("b-a6", 6, """
            The header has a theme button now: **System**, **Light** or **Dark**, remembered in `localStorage`.

            - 20 files changed, mostly fixed colors swapped for tokens
            - 48 tests pass and the build succeeds

            Dark mode toggle is ready. It follows the system setting by default.
            """),
        ], usage: usage(model: "claude-opus-5-5", used: 80_000, limit: 200_000, plan: .claude), commands: claudeCommands)
    }

    /// Claude Code on the shop API: it wrote an endpoint and waits for permission to run the
    /// migration. A yes runs it, and it then asks about a table it wants to drop.
    static var totals: Conversation {
        let run = "a-run", drop = "a-drop"
        return Conversation(backlog: [
            user("a-u1", 41, "Add an endpoint that returns an order's totals: subtotal, tax, shipping and the grand total. Right now we add them up on every request."),
            agent("a-a1", 41, "I'll check how orders are stored before adding anything."),
            tool("a-t1", "Read", "src/models/order.ts"),
            tool("a-t2", "Grep", "total in src/routes/"),
            out("a-t2", "src/routes/orders.ts:88:  const total = sum(items)\nsrc/routes/cart.ts:41:  total: sum(cart.items)"),
            tool("a-t3", "Read", "migrations/0042_shipping.sql"),
            agent("a-a2", 38, """
            Totals aren't stored anywhere: `GET /orders/:id` adds up the line items each time. I'll store them once:

            1. A migration that adds `orders.totals` and fills it from the line items
            2. `GET /orders/:id/totals`, reading that column
            3. Tests for rounding and for empty orders
            """),
            plan([("Write the migration", "completed"), ("Add the endpoint", "completed"),
                  ("Test rounding and empty orders", "completed"), ("Run the migration", "in_progress")]),
            tool("a-t4", "Write", "migrations/0043_order_totals.sql"),
            out("a-t4", "ALTER TABLE orders ADD COLUMN totals jsonb;\nUPDATE orders SET totals = order_totals(id);"),
            tool("a-t5", "Write", "src/routes/orderTotals.ts"),
            tool("a-t6", "Edit", "src/routes/index.ts"),
            tool("a-t7", "Write", "test/orderTotals.test.ts"),
            tool("a-t8", "Bash", "Run the new tests\nnpm test -- orderTotals"),
            out("a-t8", """
             ✓ returns subtotal, tax, shipping and total
             ✓ rounds half cents up
             ✓ handles an order without items
             ✓ 404s for an unknown order
             ✓ reads totals from the column
             ✓ matches the old computation for 500 orders

             Tests  6 passed (6)
            """),
            agent("a-a3", 12, """
            The endpoint is in place and its 6 tests pass against a test database. It reads the new `orders.totals` column, so the migration has to run on the dev database first:

            ```sh
            \(DemoBeat.migrationCommand)
            ```

            It adds one nullable column and fills it for 18,204 orders. Nothing is dropped.
            """),
            tool(run, "Bash", "Run the migration\n" + DemoBeat.migrationCommand),
        ], stages: [
            Stage(beat: DemoBeat.migrationRunning, after: nil, events: [
                live(0.9, out(run, "> shop-api@2.3.0 migrate")),
                live(0.9, out(run, "> shop-api@2.3.0 migrate\napplying 0043_order_totals … ok")),
                live(0.9, out(run, "> shop-api@2.3.0 migrate\napplying 0043_order_totals … ok\nbackfilling 18,204 orders … ok")),
            ]),
            Stage(beat: DemoBeat.dropQuestion, after: DemoBeat.migrationRunning, events: [
                live(0, out(run, """
                > shop-api@2.3.0 migrate
                applying 0043_order_totals … ok
                backfilling 18,204 orders … ok
                verifying totals against line items … ok

                1 migration applied in 4.2s
                """)),
                live(0, plan([("Write the migration", "completed"), ("Add the endpoint", "completed"),
                              ("Test rounding and empty orders", "completed"), ("Run the migration", "completed")])),
                live(0.3, agent("a-a4", 0, """
                Migration applied: `orders.totals` is filled in for all 18,204 orders, and `GET /orders/:id/totals` answers from it.

                One thing is left over. `order_totals_old`, a table from an earlier attempt, isn't read by anything any more. I'd like to drop it.
                """)),
                live(0.4, tool(drop, "Bash", "Drop the unused table\n" + DemoBeat.dropCommand)),
            ]),
            Stage(beat: DemoBeat.dropRunning, after: DemoBeat.dropQuestion, events: []),
            Stage(beat: DemoBeat.totalsDone, after: DemoBeat.dropRunning, events: [
                live(0, out(drop, "DROP TABLE")),
                live(0.3, agent("a-a5", 0, "Done. `order_totals_old` is gone and the totals endpoint is live on dev.")),
            ]),
            Stage(beat: DemoBeat.totalsDoneKept, after: DemoBeat.dropQuestion, events: [
                live(0.3, agent("a-a6", 0, "Okay, `order_totals_old` stays. The totals endpoint is live on dev either way.")),
            ]),
            Stage(beat: DemoBeat.migrationSkipped, after: nil, events: [
                live(0.3, agent("a-a7", 0, "Okay, I haven't run it. The migration is in `migrations/0043_order_totals.sql` for when you're ready. Until then the new endpoint fails on dev.")),
            ]),
        ], usage: usage(model: "claude-opus-5-5", used: 52_300, limit: 200_000, plan: .claude), commands: claudeCommands)
    }

    /// Codex on the infra repo, at work: the one live run. Its steps follow the terminal's status
    /// (checks, upgrade, tests), and it ends with the reply.
    static var upgrade: Conversation {
        let check = "c-check", link = "c-link", tests = "c-tests"
        func sub(_ id: String, _ parent: String, _ name: String, _ state: String, _ steps: Int, _ summary: String) -> Event {
            ["t": "subagent", "id": idPrefix + id, "parent": idPrefix + parent, "name": name, "kind": "explorer",
             "state": state, "steps": steps, "summary": summary]
        }
        func steps(_ done: Int) -> Event {
            let texts = ["Back up the staging cluster", "Check compatibility", "Upgrade with pg_upgrade --link",
                         "Run the tests against Postgres 18"]
            return plan(texts.enumerated().map { ($1, $0 < done ? "completed" : $0 == done ? "in_progress" : "pending") })
        }
        let checks = ["Checking cluster versions       ok", "Checking database connection    ok",
                      "Checking data types             ok", "Checking extension updates      ok",
                      "Checking tablespaces            ok", "*Clusters are compatible*"]
        func checked(_ n: Int) -> Event { out(check, checks.prefix(n).joined(separator: "\n")) }
        let passing = ["api/orders        58 passed", "api/catalog       41 passed", "jobs/billing      37 passed",
                       "jobs/search       29 passed", "migrations        47 passed", "212 passed, 0 failed in 48.1s"]
        func passed(_ n: Int) -> Event { out(tests, passing.prefix(n).joined(separator: "\n")) }
        return Conversation(backlog: [
            user("c-u1", 34, "Upgrade the staging database to Postgres 18 and make sure nothing breaks."),
            agent("c-a1", 34, "I'll take a dump first, then check compatibility before touching the cluster."),
            tool("c-t1", "shell", "psql -c 'select version()'"),
            out("c-t1", "PostgreSQL 17.4 on x86_64-pc-linux-gnu"),
            tool("c-t2", "shell", "pg_dumpall > /backups/pre-18.sql"),
            tool("c-t3", "shell", "ls -lh /backups/pre-18.sql"),
            out("c-t3", "-rw-r--r-- 1 postgres postgres 2.1G pre-18.sql"),
            ["t": "msg", "id": idPrefix + "c-n1", "role": "note", "text": "Used memory: staging backups live in /backups, not the app volume"],
            agent("c-a2", 6, "The dump is 2.1 GB in `/backups/pre-18.sql`. Two sub-agents are reading what changed for our extensions and settings between 17 and 18 while I run the checks."),
            steps(1),
            tool("c-s1t", "spawn_agent", "Check the extensions against 18"),
            tool("c-s2t", "spawn_agent", "Review renamed settings"),
            tool(check, "shell", "pg_upgrade --check -b /usr/lib/postgresql/17/bin -B /usr/lib/postgresql/18/bin"),
            sub("c-s1", "c-s1t", "Check extensions", "running", 3, "Reading the pg_stat_statements changelog"),
            sub("c-s2", "c-s2t", "Review settings", "running", 2, "Comparing postgresql.conf with the 18 defaults"),
        ], stages: [
            Stage(beat: DemoBeat.upgradeChecks, after: nil, events: [
                live(1.5, checked(1)),
                live(1.2, sub("c-s1", "c-s1t", "Check extensions", "running", 5, "pg_stat_statements and pgcrypto both ship with 18")),
                live(1.3, checked(2)),
                live(1.5, sub("c-s2", "c-s2t", "Review settings", "running", 4, "One setting was renamed in 18")),
                live(1.5, checked(3)),
                live(2.5, checked(4)),
            ]),
            Stage(beat: DemoBeat.upgradeRunning, after: DemoBeat.upgradeChecks, events: [
                live(0, checked(6)),
                live(0, sub("c-s1", "c-s1t", "Check extensions", "done", 6, "All four extensions have builds for 18")),
                live(0, sub("c-s2", "c-s2t", "Review settings", "done", 5, "Only vacuum_buffer_usage_limit needs a new value")),
                live(0.4, steps(2)),
                live(0.6, tool(link, "shell", "pg_upgrade --link -b /usr/lib/postgresql/17/bin -B /usr/lib/postgresql/18/bin")),
                live(2, out(link, "Dumping global objects          ok")),
                live(2.5, out(link, "Dumping global objects          ok\nRestoring schemas               ok")),
                live(2.5, out(link, "Dumping global objects          ok\nRestoring schemas               ok\nLinking relation files          ok")),
            ]),
            Stage(beat: DemoBeat.upgradeTests, after: DemoBeat.upgradeRunning, events: [
                live(0, out(link, "Dumping global objects          ok\nRestoring schemas               ok\nLinking relation files          ok\nSetting next OID                ok\n\nUpgrade Complete")),
                live(0.4, steps(3)),
                live(0.6, tool(tests, "shell", "make test DB=staging")),
                live(2, passed(1)),
                live(2, passed(2)),
                live(2, passed(3)),
                live(2.5, passed(4)),
            ]),
            Stage(beat: DemoBeat.upgradeDone, after: DemoBeat.upgradeTests, events: [
                live(0, passed(6)),
                live(0.3, steps(4)),
                live(0.5, agent("c-a3", 0, """
                Staging is on **Postgres 18.1** and every check is green.

                ```sh
                $ psql -c 'show server_version'
                 18.1
                ```

                - The upgrade used `--link`, so it took 40 seconds and no extra disk.
                - The dump from before is in `/backups/pre-18.sql` if we need to roll back.
                - All 212 tests pass against the new server.
                """)),
            ]),
        ], usage: usage(model: "gpt-6.1-sol", used: 198_560, limit: 272_000, plan: .codex), commands: codexCommands)
    }

    /// Codex in a worktree of the shop API: it measured, prepared the change and asks where the
    /// cache should live. The question is answered from the reply box.
    static var cache: Conversation {
        Conversation(backlog: [
            user("d-u1", 75, "The catalog page fetches every product image again on each visit. Cache them."),
            agent("d-a1", 75, "I'll measure first, so we know what the cache has to hold."),
            tool("d-t1", "shell", "rg -n productImage src/"),
            out("d-t1", "src/routes/products.ts:31:  const image = await productImage(id)\nsrc/images/fetch.ts:9:export async function productImage(id) {"),
            tool("d-t2", "shell", "node scripts/measure-catalog.js"),
            out("d-t2", """
            GET /catalog
              image requests      212
              cache hits            0
              bytes fetched     38.4 MB
              slowest image     840 ms
              page complete    4.61 s
            """),
            agent("d-a2", 52, """
            One catalog page makes **212 image requests** (38 MB), and none of them hit a cache. I added an `ImageCache` interface and sent the fetch path through it. Where the bytes live is the open choice:

            - **On disk**: simple and survives restarts, but each of the three API servers keeps its own copy.
            - **In Redis**: shared by all three, and needs a size limit so it can't push out sessions.
            """),
            tool("d-t3", "apply_patch", "src/images/cache.ts"),
            tool("d-t4", "apply_patch", "src/routes/products.ts"),
            ["t": "question", "id": cacheQuestion, "title": DemoBeat.cacheQuestion,
             "options": ["In Redis (Recommended)", "On disk"],
             "details": ["Shared by all three servers, with a size limit so it can't push out sessions.",
                         "Simple and survives restarts, but each server keeps its own copy."],
             "header": "Image cache", "async": true, "group": idPrefix + "d-q", "index": 0, "count": 1],
        ], stages: [
            Stage(beat: DemoBeat.cacheRunning, after: nil, events: [
                live(0.5, agent("d-a3", 0, "Going with that. I'll wire the cache in behind the interface and run the image tests.")),
                live(0.6, tool("d-t5", "apply_patch", "src/images/store.ts")),
                live(0.8, tool("d-t6", "shell", "npm test -- images")),
                live(1.2, out("d-t6", " ✓ stores an image on first fetch")),
                live(0.8, out("d-t6", " ✓ stores an image on first fetch\n ✓ serves the second fetch from the cache")),
            ]),
            Stage(beat: DemoBeat.cacheDone, after: DemoBeat.cacheRunning, events: [
                live(0, out("d-t6", " ✓ stores an image on first fetch\n ✓ serves the second fetch from the cache\n ✓ evicts the oldest image at the size limit\n\n Tests  3 passed (3)")),
                live(0.4, agent("d-a4", 0, "Product images are cached now. A second visit to the catalog makes **4** image requests instead of 212, and the page completes in 0.9 s.")),
            ]),
        ], usage: usage(model: "gpt-6.1-sol", used: 61_300, limit: 272_000, plan: .codex), commands: codexCommands)
    }

    static let cacheQuestion = idPrefix + "d-q-q0"

    /// Antigravity on the Windows laptop: a finished fix, read long ago.
    static var flakyTest: Conversation {
        var events: [Event] = [
            user("e-u1", 190, "The checkout test fails about one run in ten on CI. Find out why and fix it."),
            tool("e-t1", "run_command", "npx vitest run checkout --repeat 50"),
            out("e-t1", """
             FAIL  test\\checkout.test.ts (run 7, 19, 33, 41)
              ● checkout › charges the card once
                expected mockPayment to be called 1 time, got 0

             Runs  46 passed | 4 failed (50)
            """, failed: true),
            tool("e-t2", "view_file", "test\\checkout.test.ts"),
            tool("e-t3", "grep_search", "mockPayment in test\\"),
            agent("e-a1", 150, "It's a race. The test clicks **Pay** right after rendering, and in 4 of 50 runs the payment mock hasn't registered yet, so the click goes nowhere. The app is fine; the test has to wait for the mock."),
            tool("e-t4", "replace_file_content", "test\\checkout.test.ts"),
            tool("e-t5", "run_command", "npx vitest run checkout --repeat 50"),
            out("e-t5", """
             ✓ test\\checkout.test.ts (50 runs)
               ✓ checkout › charges the card once
               ✓ checkout › shows the receipt
               ✓ checkout › keeps the cart on failure

             Runs  50 passed (50)
            """),
        ]
        if let image = sampleImage() {
            events.append(["t": "image", "id": idPrefix + "e-i1", "role": "assistant", "mime": "image/png",
                           "data": image.base64EncodedString()])
        }
        events.append(agent("e-a2", 125, "Fixed. The test now awaits `mockPayment.ready` before clicking, and 50 runs in a row pass. The picture is the checkout page as the test sees it at that moment."))
        return Conversation(backlog: events,
                            usage: usage(model: "gemini-3.5-pro", used: 46_800, limit: 1_000_000, plan: nil),
                            commands: [])
    }

    // MARK: What the on-device model would write

    /// One line under a run of steps whose output is long, by the step's id; and a few words for a
    /// run of several steps, by "steps|" and its last step's id.
    static let summaries: [String: String] = {
        let lines = [
            "b-t7": "1 of 48 tests failed: the Header snapshot is out of date",
            "b-t9": "48 tests passed in 12 seconds",
            "b-t10": "20 files changed, mostly header and theme styles",
            "b-t11": "Build succeeded; bundle grew by 2 KB",
            "a-t8": "6 tests passed in orderTotals.test.ts",
            "a-run": "Migration 0043 applied; 18,204 orders backfilled",
            "c-check": "All six checks passed; the clusters are compatible",
            "c-link": "Upgrade complete; relation files were linked",
            "c-tests": "212 tests passed, none failed, in 48 seconds",
            "d-t2": "212 image requests per page, 38 MB, no cache hits",
            "d-t6": "3 image cache tests passed",
            "e-t1": "4 of 50 runs failed: mockPayment was never called",
            "e-t5": "All 50 runs of the checkout test passed",
        ]
        let gists = [
            "b-t3": "Find where the theme is set",
            "b-t8": "Add the toggle and run the tests",
            "a-t3": "Read the order model and routes",
            "a-t8": "Add the migration, endpoint and tests",
            "c-t3": "Check the version and take a dump",
            "c-link": "Check compatibility and upgrade",
            "c-tests": "Check, upgrade and run the tests",
            "d-t2": "Measure the catalog's image requests",
            "d-t4": "Send image fetches through a cache",
            "d-t6": "Wire in the cache and test it",
            "e-t3": "Reproduce the failure and read the test",
            "e-t5": "Await the mock and rerun 50 times",
        ]
        var out: [String: String] = [:]
        for (id, line) in lines { out[idPrefix + id] = line }
        for (id, gist) in gists { out["steps|" + idPrefix + id] = gist }
        return out
    }()

    /// Reply suggestions, by the id of the agent's message they follow.
    static let chips: [String: [String]] = [
        idPrefix + "b-a6": ["Show me what changed", "Run it on the staging site"],
        idPrefix + "c-a3": ["Upgrade production next"],
        idPrefix + "e-a2": ["Run it on CI too"],
    ]

    /// What the away card says about an agent, by terminal address.
    static let digest: [String: String] = [
        DemoBeat.websiteAgent: "Dark mode toggle is ready; 20 files changed, tests pass",
        DemoBeat.totalsAgent: "Wants to run the orders migration",
        DemoBeat.cacheAgent: "Asks where product images should be cached",
    ]

    /// One sentence on what a dangerous command would do (the second permission prompt).
    static func explanation(for command: String) -> String? {
        command.contains(DemoBeat.dropCommand)
            ? "Permanently deletes the order_totals_old table and all its rows from the shop database." : nil
    }

    /// The Changes sheet's sentence on top, by folder.
    static func changesSummary(folder: String) -> String? {
        folder == DemoBeat.website
            ? "Adds a dark mode toggle to the header and theme variables for both appearances." : nil
    }

    /// Puts the fixed text where the on-device model's would go. Safe to call again.
    static func seed() {
        ToolOutputSummaries.shared.seedDemo(summaries)
        ReplySuggestions.shared.seedDemo(chips)
    }

    /// The same, when a demo machine connects, with its plan windows' history.
    static func seed(machine: String) {
        seed()
        UsageHistory.shared.seedDemo(history(machine: machine, agent: .claude) + history(machine: machine, agent: .codex))
    }

    /// Sub-agents the upgrade agent runs while it checks compatibility (the list shows the count
    /// before its chat was opened).
    static func runningSubagents(address: String, status: TerminalStatus?) -> Int {
        address == DemoBeat.upgradeAgent && status?.msg == DemoBeat.upgradeChecks ? 2 : 0
    }

    // MARK: Commands

    private static func commands(_ items: [(String, String)]) -> [Event] {
        [["t": "commands", "items": items.map { ["name": $0.0, "description": $0.1] }]]
    }

    static let claudeCommands = commands([
        ("/clear", "Start a new conversation"), ("/compact", "Summarize the conversation to free up context"),
        ("/context", "Show what fills the context window"), ("/model", "Switch the model"),
        ("/review", "Review the changes on this branch"), ("/resume", "Continue an earlier conversation"),
        ("/deploy-staging", "Build and deploy this branch to the staging site"),
        ("/release-notes", "Write release notes from the commits since the last tag"),
    ])

    static let codexCommands = commands([
        ("/compact", "Summarize the conversation to free up context"), ("/diff", "Show the working tree's changes"),
        ("/model", "Switch the model and reasoning effort"), ("/review", "Review the current changes"),
        ("/status", "Show the session's settings and token use"),
        ("$db-migration", "Write and check a database migration"),
        ("$release-notes", "Write release notes from the commits since the last tag"),
    ])

    // MARK: Usage

    enum Plan { case claude, codex }

    /// Plan windows reset at fixed times, the same for every reading of a launch (the history's
    /// forecast compares them).
    static let claudeSessionReset = (start.timeIntervalSince1970 + 190 * 60).rounded()
    static let codexSessionReset = (start.timeIntervalSince1970 + 95 * 60).rounded()
    /// Next Thursday, 09:00.
    static let weeklyReset: Double = {
        let calendar = Calendar.current
        let next = calendar.nextDate(after: start, matching: DateComponents(hour: 9, minute: 0, weekday: 5),
                                     matchingPolicy: .nextTime) ?? start.addingTimeInterval(3 * 86_400)
        return next.timeIntervalSince1970.rounded()
    }()

    /// `-bergr.demoLimit YES` (screenshots): Claude's session window is used up, so the chat shows
    /// the limit bar with Continue Then.
    static let limitReached = UserDefaults.standard.bool(forKey: "bergr.demoLimit")
    static let claudeSession = limitReached ? 100.0 : 62.0, claudeWeekly = 41.0, codexSession = 18.0

    static func usage(model: String, used: Int, limit: Int, plan: Plan?) -> Event {
        var event: Event = ["t": "usage", "model": model, "used": used, "limit": limit]
        switch plan {
        case .claude:
            event["session"] = ["percent": claudeSession, "resets_at": claudeSessionReset]
            event["weekly"] = ["percent": claudeWeekly, "resets_at": weeklyReset]
        case .codex:
            event["session"] = ["percent": codexSession, "resets_at": codexSessionReset]
        case nil:
            break
        }
        return event
    }

    /// An agent's usage without opening its chat (the Usage screen).
    static func usage(address: String, agent: ChatAgent) -> ChatFeed.Usage? {
        ChatFeed.Usage(event: conversation(address: address, agent: agent).usage)
    }

    /// Readings of the last week for a machine's plan windows: two earlier sessions and the
    /// current one (so the chart draws two resets), rising in the last hour at a rate that reaches
    /// the limit before the window resets.
    static func history(machine: String, agent: ChatAgent, now: Date = start) -> [UsageHistory.Entry] {
        func run(_ kind: String, from: Double, to: Double, startHoursAgo: Double, hours: Double, resetsAt: Double?,
                 points: Int) -> [UsageHistory.Entry] {
            (0..<points).map { i in
                let t = Double(i) / Double(points - 1)
                return UsageHistory.Entry(
                    key: UsageHistory.key(machine: machine, agent: agent.rawValue, kind: kind),
                    time: now.addingTimeInterval(-(startHoursAgo - hours * t) * 3600),
                    percent: (from + (to - from) * t).rounded(),
                    resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
            }
        }
        switch agent {
        case .claude:
            // A week of real-looking use: 5-hour session windows in the day (climbing in uneven
            // steps, some hitting 100% and sitting there until the reset), quiet nights, and a
            // weekly window that steps up with them. The current window ends at `claudeSession`.
            let windows: [(start: Double, peak: Double)] = [
                (158, 64), (153, 100), (134, 48), (129, 92), (110, 100), (105, 37), (86, 71), (81, 100),
                (62, 55), (57, 100), (38, 83), (33, 44), (14, 100), (9, 58)]
            var session: [UsageHistory.Entry] = []
            for (n, w) in windows.enumerated() {
                session += window(machine: machine, agent: agent, now: now, startHoursAgo: w.start, peak: w.peak, seed: n)
            }
            session += window(machine: machine, agent: agent, now: now, startHoursAgo: 3, peak: claudeSession,
                              seed: 99, until: 0, resetsAt: claudeSessionReset)
            return session + weekly(machine: machine, agent: agent, sessions: session, now: now,
                                    to: claudeWeekly, resetsAt: weeklyReset)
        case .codex:
            var session: [UsageHistory.Entry] = []
            for (n, w) in [(100.0, 40.0), (76, 100), (52, 66), (28, 81)].enumerated() {
                session += window(machine: machine, agent: agent, now: now, startHoursAgo: w.0, peak: w.1, seed: 50 + n)
            }
            return session + window(machine: machine, agent: agent, now: now, startHoursAgo: 1.2, peak: codexSession,
                                    seed: 77, until: 0, resetsAt: codexSessionReset)
        case .antigravity:
            return []
        }
    }

    /// One session window's readings, every 15 minutes: bursts of work and pauses, up to `peak`;
    /// at 100% it stays there until the window's 5 hours are up. `until` cuts it off (hours ago).
    private static func window(machine: String, agent: ChatAgent, now: Date, startHoursAgo: Double, peak: Double,
                               seed: Int, until: Double? = nil, resetsAt: Double? = nil) -> [UsageHistory.Entry] {
        let key = UsageHistory.key(machine: machine, agent: agent.rawValue, kind: "session")
        var rng = UInt64(seed &* 2_654_435_761 &+ 1)
        func next() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double(rng >> 33) / Double(1 << 31) }
        let end = max(until ?? (startHoursAgo - 5), startHoursAgo - 5)
        let climb = peak >= 100 ? 3.0 + next() * 1.2 : startHoursAgo - end
        var steps: [Double] = []
        var t = 0.0
        while t <= startHoursAgo - end + 0.001 { steps.append(t); t += 0.25 }
        // Uneven growth: each step adds a random share, some steps (pauses) nothing.
        let weights = steps.map { _ in next() < 0.3 ? 0 : 0.3 + next() }
        let climbing = steps.filter { $0 <= climb }.count
        let total = max(0.001, weights.prefix(climbing).reduce(0, +))
        var used = 1 + next() * 4, out: [UsageHistory.Entry] = []
        for (i, h) in steps.enumerated() {
            if h <= climb { used += (min(peak, 100) - 5) * weights[i] / total }
            let percent = h <= climb ? min(used, peak) : min(100, peak)
            out.append(UsageHistory.Entry(key: key, time: now.addingTimeInterval(-(startHoursAgo - h) * 3600),
                                          percent: percent.rounded(),
                                          resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) }))
        }
        if let last = out.indices.last, until != nil { out[last].percent = peak }
        return out
    }

    /// The weekly window, rising in step with the session windows' use and ending at `to` now.
    private static func weekly(machine: String, agent: ChatAgent, sessions: [UsageHistory.Entry], now: Date,
                               to: Double, resetsAt: Double) -> [UsageHistory.Entry] {
        let key = UsageHistory.key(machine: machine, agent: agent.rawValue, kind: "weekly")
        var spent = 0.0, last = 0.0, points: [(Date, Double)] = []
        for e in sessions.sorted(by: { $0.time < $1.time }) {
            spent += max(0, e.percent - last)
            last = e.percent
            points.append((e.time, spent))
        }
        guard let total = points.last?.1, total > 0 else { return [] }
        return points.enumerated().compactMap { i, p in
            i % 2 == 0 || i == points.count - 1
                ? UsageHistory.Entry(key: key, time: p.0, percent: (to * p.1 / total).rounded(),
                                     resetsAt: Date(timeIntervalSince1970: resetsAt))
                : nil
        }
    }

    // MARK: The machines' command channel

    private struct Repo {
        var folder: String
        var branch: String
        /// The main repository's folder when this is a linked worktree.
        var worktreeOf: String?
        var files: [(path: String, plus: Int, minus: Int)]
        var untracked: [String] = []
    }

    private static let repos: [Repo] = [
        Repo(folder: DemoBeat.website, branch: "feature/dark-mode", files: [
            ("src/components/Header.tsx", 10, 4), ("src/styles/theme.css", 39, 2), ("src/styles/buttons.css", 4, 4),
            ("src/styles/cards.css", 3, 3), ("src/styles/forms.css", 6, 6), ("src/styles/footer.css", 2, 2),
            ("src/styles/nav.css", 5, 5), ("src/styles/tables.css", 4, 4), ("src/styles/modal.css", 3, 3),
            ("src/styles/badges.css", 2, 2), ("src/styles/cart.css", 4, 4), ("src/styles/checkout.css", 5, 5),
            ("src/styles/product.css", 4, 4), ("src/styles/search.css", 2, 2), ("src/styles/toast.css", 2, 2),
            ("src/pages/Settings.tsx", 3, 2), ("src/theme/tokens.ts", 18, 1), ("src/theme/tokens.test.ts", 22, 0),
            ("src/components/Header.test.tsx", 8, 1),
            ("src/components/__snapshots__/Header.test.tsx.snap", 6, 3),
        ], untracked: ["src/components/ThemeToggle.tsx"]),
        Repo(folder: DemoBeat.shopAPI, branch: "feature/order-totals", files: [("src/routes/index.ts", 2, 0)],
             untracked: ["migrations/0043_order_totals.sql", "src/routes/orderTotals.ts", "test/orderTotals.test.ts"]),
        Repo(folder: DemoBeat.infra, branch: "main", files: [("postgres/staging.conf", 3, 2)]),
        Repo(folder: DemoBeat.cacheWorktree, branch: "codex/cache-images", worktreeOf: "/home/demo/projects/shop-api",
             files: [("src/routes/products.ts", 6, 2)], untracked: ["src/images/cache.ts"]),
        Repo(folder: DemoBeat.windowsWebsite, branch: "fix/flaky-checkout", files: [("test/checkout.test.ts", 3, 1)]),
    ]

    private static let headerDiff = """
        diff --git a/src/components/Header.tsx b/src/components/Header.tsx
        index 3f1c2aa..9b7d410 100644
        --- a/src/components/Header.tsx
        +++ b/src/components/Header.tsx
        @@ -1,4 +1,5 @@
         import { Logo } from './Logo'
        -import { CartButton } from './CartButton'
        +import { CartButton } from './cart/CartButton'
        +import { ThemeToggle } from './ThemeToggle'
         import './header.css'
        @@ -12,9 +13,13 @@ export function Header({ cart }: Props) {
           return (
             <nav className="header">
               <Logo />
        -      <CartButton count={cart.count} />
        +      <div className="header-actions">
        +        <ThemeToggle />
        +        <CartButton count={cart.count} />
        +      </div>
             </nav>
           )
         }
        """

    private static func diff(_ file: (path: String, plus: Int, minus: Int)) -> String {
        if file.path == "src/components/Header.tsx" { return headerDiff }
        let removed = (0..<file.minus).map { "-  color: #1f2124; /* \($0 + 1) */" }
        let added = (0..<file.plus).map { "+  color: var(--fg); /* \($0 + 1) */" }
        return (["diff --git a/\(file.path) b/\(file.path)", "--- a/\(file.path)", "+++ b/\(file.path)",
                 "@@ -1,\(file.minus + 2) +1,\(file.plus + 2) @@", " /* theme */"] + removed + added + [" /* end */"])
            .joined(separator: "\n")
    }

    struct NoAnswer: Error {}

    /// Fixed text in place of the on-device model's (nil: nothing is written).
    struct FixedText: OnDeviceTextWriting {
        let reply: String?
        func write(instructions: String, prompt: String, timeout: Duration) async -> String? { reply }
    }

    /// What a demo machine prints for the few git commands the app runs: the branch of a row, and
    /// the Changes sheet's status, stat and diffs. Anything else fails, as on a machine that can't
    /// run commands.
    static func commandOutput(_ command: String) throws -> String {
        // The longest folder named in the command (the cache worktree's path contains the API's).
        guard let repo = repos.filter({ command.contains($0.folder) }).max(by: { $0.folder.count < $1.folder.count }),
              command.contains("git") else { throw NoAnswer() }
        let stat = repo.files.map { file in
            " \(file.path) | \(file.plus + file.minus) " + String(repeating: "+", count: file.plus)
                + String(repeating: "-", count: file.minus)
        }.joined(separator: "\n") + "\n \(repo.files.count) files changed, \(repo.files.map(\.plus).reduce(0, +)) insertions(+), "
            + "\(repo.files.map(\.minus).reduce(0, +)) deletions(-)\n"
        if command.contains("rev-parse --abbrev-ref HEAD") {
            // Only the worktree's row names its branch: five rows with one each crowd the list.
            guard repo.worktreeOf != nil else { throw NoAnswer() }
            let gitDir = repo.worktreeOf.map { "\($0)/.git/worktrees/\(repo.branch.split(separator: "/").last ?? "x")" } ?? ".git"
            return [repo.branch, gitDir, repo.worktreeOf.map { $0 + "/.git" } ?? ".git"].joined(separator: "\n") + "\n"
        }
        if command.contains("status --porcelain") {
            return (["## \(repo.branch)...origin/\(repo.branch)"] + repo.files.map { " M " + $0.path }
                + repo.untracked.map { "?? " + $0 }).joined(separator: "\n") + "\n"
        }
        if command.contains("rev-parse --verify") { return "4c1d2e7a90b35f6688d1a2c3b4e5f60718293a4b\n" }
        if command.contains("ls-files --others") { return repo.untracked.joined(separator: "\n") + "\n" }
        if command.contains("cat-file -p") { return "" }
        if command.contains("--stat") { return stat }
        if command.contains(" diff ") {
            if let file = repo.files.first(where: { command.contains("\"\($0.path)\"") }) { return diff(file) + "\n" }
            return repo.files.prefix(3).map(diff).joined(separator: "\n") + "\n"
        }
        throw NoAnswer()
    }

    // MARK: Pictures

    /// A small picture drawn in code, for the image bubble.
    static func sampleImage() -> Data? {
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
        return image.pngData()
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// A scanned page with a hand-drawn cache diagram: the picture attached to the reply about
    /// where images are cached (`-bergr.demoAttach YES`).
    static func sketch() -> UIImage {
        let size = CGSize(width: 600, height: 780)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let ink = UIColor(red: 0.13, green: 0.17, blue: 0.36, alpha: 1)
            ink.setStroke()
            func box(_ rect: CGRect, _ label: String) {
                let path = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 14)
                path.lineWidth = 5
                path.stroke()
                let text = NSAttributedString(string: label, attributes: [
                    .font: UIFont(name: "Noteworthy-Bold", size: 34) ?? .boldSystemFont(ofSize: 34), .foregroundColor: ink])
                let s = text.size()
                text.draw(at: CGPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2))
            }
            func arrow(from a: CGPoint, to b: CGPoint) {
                let path = UIBezierPath()
                path.move(to: a)
                path.addLine(to: b)
                let angle = atan2(b.y - a.y, b.x - a.x)
                for turn in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
                    path.move(to: b)
                    path.addLine(to: CGPoint(x: b.x + 26 * cos(angle + turn), y: b.y + 26 * sin(angle + turn)))
                }
                path.lineWidth = 5
                path.lineCapStyle = .round
                path.stroke()
            }
            for (i, name) in ["api 1", "api 2", "api 3"].enumerated() {
                let rect = CGRect(x: 40 + CGFloat(i) * 185, y: 110, width: 150, height: 90)
                box(rect, name)
                arrow(from: CGPoint(x: rect.midX, y: rect.maxY + 8), to: CGPoint(x: 300 + CGFloat(i - 1) * 50, y: 372))
            }
            box(CGRect(x: 190, y: 380, width: 220, height: 110), "Redis")
            arrow(from: CGPoint(x: 300, y: 498), to: CGPoint(x: 300, y: 600))
            box(CGRect(x: 160, y: 608, width: 280, height: 100), "image store")
            NSAttributedString(string: "one cache for all three", attributes: [
                .font: UIFont(name: "Noteworthy-Light", size: 28) ?? .systemFont(ofSize: 28), .foregroundColor: ink])
                .draw(at: CGPoint(x: 150, y: 40))
        }
    }
    #endif
}

extension ChatFeed {
    /// A sample conversation, for the design preview: Claude's finished turn, or Codex at work.
    func loadSample(_ agent: ChatAgent = .claude) {
        loadDemo(agent == .codex ? DemoChat.upgrade : DemoChat.website)
    }

    /// A demo conversation as it stands when the chat opens.
    func loadDemo(_ conversation: DemoChat.Conversation) {
        // Sub-agents live beside the conversation, not in it.
        let isSubagent = { (event: DemoChat.Event) in event["t"] as? String == "subagent" }
        loadEvents(conversation.backlog.filter { !isSubagent($0) } + [conversation.usage])
        for event in conversation.backlog.filter(isSubagent) + conversation.commands { applyDemo(event) }
    }

    /// A demo machine's agent: its conversation, then what its terminal's status brings (an answer
    /// given, a run that goes on), until the chat goes away.
    func runDemo(address: String, agent: ChatAgent, status: @escaping @MainActor () -> TerminalStatus?) async {
        #if DEBUG
        let turns = UserDefaults.standard.integer(forKey: "bergr.stress")
        if turns > 0 { await runStress(turns: turns); return }
        #endif
        DemoChat.seed()
        /// A message that arrives now was written now.
        func stamped(_ event: DemoChat.Event) -> DemoChat.Event {
            guard event["t"] as? String == "msg" else { return event }
            return event.merging(["at": Date.now.timeIntervalSince1970.rounded()]) { $1 }
        }
        let conversation = DemoChat.conversation(address: address, agent: agent)
        loadDemo(conversation)
        var applied: Set<String> = []
        while !Task.isCancelled {
            if let stage = conversation.stage(for: status()), !applied.contains(stage.beat) {
                // Stages the chat wasn't open for are simply there.
                for earlier in conversation.chain(before: stage) where applied.insert(earlier.beat).inserted {
                    for timed in earlier.events { applyDemo(stamped(timed.event)) }
                }
                applied.insert(stage.beat)
                for timed in stage.events {
                    // Wait while this is still what the agent does; once it moved on, catch up.
                    var left = timed.wait
                    while left > .zero, !Task.isCancelled, conversation.stage(for: status())?.beat == stage.beat {
                        try? await Task.sleep(for: .milliseconds(100))
                        left -= .milliseconds(100)
                    }
                    applyDemo(stamped(timed.event))
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The fake agent hears a reply: it shows up, a few steps run, then an answer comes.
    func demoUserSaid(_ text: String) {
        let n = items.count
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            demoWorking = true
            applyDemo(["t": "msg", "id": "demo-u\(n)", "role": "user", "text": text, "at": Date.now.timeIntervalSince1970.rounded()])
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
            applyDemo(["t": "msg", "id": "demo-a\(n)", "role": "assistant", "at": Date.now.timeIntervalSince1970.rounded(), "text": """
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
