// Modified for Bergr, 2026, from Hirte (Apache-2.0). See the git history for all changes.
import Foundation

/// One of the demo's machines. The first is the one "Try the Demo" opens; the others make the
/// agents list read as several machines.
public enum DemoMachine: String, CaseIterable, Sendable {
    case studio, buildbox, winbook

    /// The name the machine shows under.
    public var name: String { rawValue }

    /// The host name a saved demo machine carries (`demo`, `demo-buildbox`, …).
    public var target: String { self == .studio ? "demo" : "demo-" + rawValue }

    public init?(target: String) {
        guard let found = Self.allCases.first(where: { $0.target == target }) else { return nil }
        self = found
    }

    public var isWindows: Bool { self == .winbook }
}

/// The demo's agents and the status lines that change while it runs. The app's demo conversations
/// follow them, so a chat shows what its terminal's status says.
public enum DemoBeat {
    /// The terminals that run an agent (addresses differ across the machines, so a row is found by
    /// its address alone).
    public static let websiteAgent = "t1"
    public static let totalsAgent = "t3"
    public static let upgradeAgent = "t11"
    public static let cacheAgent = "t12"
    public static let flakyTestAgent = "t21"

    public static let migrationQuestion = "Run the database migration?"
    public static let migrationRunning = "Running the migration"
    public static let migrationSkipped = "Migration skipped"
    public static let dropQuestion = "Drop the old totals table?"
    public static let dropRunning = "Dropping the old table"
    public static let totalsDone = "Migration applied, old table dropped"
    public static let totalsDoneKept = "Migration applied, old table kept"

    public static let upgradeChecks = "Running pg_upgrade checks"
    public static let upgradeRunning = "Upgrading the cluster"
    public static let upgradeTests = "Running the test suite"
    public static let upgradeDone = "All checks green"

    public static let cacheQuestion = "Where should product images be cached?"
    public static let cacheRunning = "Wiring in the cache"
    public static let cacheDone = "Images cached, tests pass"

    /// The commands the two permission prompts ask about.
    public static let migrationCommand = "npm run migrate -- --name add_order_totals"
    public static let dropCommand = #"psql shop -c "DROP TABLE order_totals_old""#

    /// Folders of the agents.
    public static let website = "/Users/demo/projects/website"
    public static let shopAPI = "/Users/demo/projects/shop-api"
    public static let infra = "/home/demo/projects/infra"
    public static let cacheWorktree = "/home/demo/projects/shop-api-cache-images"
    public static let windowsWebsite = #"C:\Users\demo\projects\website"#
}

/// What the demo machines show: a small shop's projects with agents, tests, a dev server and a
/// shell. Lines stay under ~44 columns so screens read well on a folded phone.
enum DemoScript {
    static let home = "/Users/demo"
    static let website = DemoBeat.website
    static let shopAPI = DemoBeat.shopAPI
    static let infra = DemoBeat.infra
    static let cacheWorktree = DemoBeat.cacheWorktree

    static let now = UInt64(Date().timeIntervalSince1970 * 1000)

    private static func ago(minutes: UInt64) -> UInt64 { now - minutes * 60_000 }

    /// herdr's shared read state: the last turn someone looked at.
    private static func seen(_ turn: UInt64) -> [String: String] { [Terminal.seenLabel: String(turn)] }

    // MARK: Terminals

    static func terminals(_ machine: DemoMachine = .studio) -> [DemoTerminal] {
        switch machine {
        case .studio: studioTerminals
        case .buildbox: buildboxTerminals
        case .winbook: winbookTerminals
        }
    }

    private static var studioTerminals: [DemoTerminal] {
        [
            DemoTerminal(
                address: "t1", argv: ["claude"], cwd: website, title: "claude",
                status: .init(state: "done", app: "claude-code", title: "Add a dark mode toggle", msg: "20 files changed"),
                // Finished a turn nobody has looked at yet.
                labels: seen(2), foreground: .init(pid: 31_201, name: "claude", argv: ["claude"], cwd: website),
                createdMs: ago(minutes: 58), turn: 3, statusMs: ago(minutes: 6)),
            DemoTerminal(
                address: "t2", name: "tests", argv: ["npm", "test", "--", "--watch"], cwd: website,
                foreground: .init(pid: 31_377, name: "node", argv: ["node", "vitest", "--watch"], cwd: website),
                createdMs: ago(minutes: 30), parent: "t1"),
            DemoTerminal(
                address: "t3", argv: ["claude"], cwd: shopAPI, title: "claude",
                status: .init(state: "blocked", app: "claude-code", title: DemoBeat.migrationQuestion,
                              msg: "Add order totals endpoint", kind: "permission"),
                labels: seen(1), foreground: .init(pid: 30_822, name: "claude", argv: ["claude"], cwd: shopAPI),
                createdMs: ago(minutes: 41), turn: 1, statusMs: ago(minutes: 12)),
            DemoTerminal(
                address: "t4", name: "dev-server", argv: ["npm", "run", "dev"], cwd: website,
                foreground: .init(pid: 29_910, name: "node", argv: ["node", "vite"], cwd: website),
                createdMs: ago(minutes: 95)),
            DemoTerminal(
                address: "t5", argv: ["zsh"], cwd: shopAPI,
                foreground: .init(pid: 30_100, name: "zsh", argv: ["zsh"], cwd: shopAPI),
                createdMs: ago(minutes: 64)),
            DemoTerminal(
                address: "t7", name: "nightly-backup", argv: ["./backup.sh"], cwd: shopAPI, state: "finished",
                createdMs: ago(minutes: 300), exitCode: 0, reason: "exited"),
        ]
    }

    private static var buildboxTerminals: [DemoTerminal] {
        [
            DemoTerminal(
                address: "t11", argv: ["codex"], cwd: infra, title: "codex",
                status: .init(state: "working", app: "codex", title: "Upgrade Postgres to 18",
                              msg: DemoBeat.upgradeChecks, progress: 55),
                labels: seen(1), foreground: .init(pid: 28_456, name: "codex", argv: ["codex"], cwd: infra),
                createdMs: ago(minutes: 34), turn: 1, statusMs: ago(minutes: 4)),
            DemoTerminal(
                address: "t12", argv: ["codex"], cwd: cacheWorktree, title: "codex",
                status: .init(state: "blocked", app: "codex", title: DemoBeat.cacheQuestion,
                              msg: "Cache product images", kind: "question"),
                labels: seen(1), foreground: .init(pid: 28_911, name: "codex", argv: ["codex"], cwd: cacheWorktree),
                createdMs: ago(minutes: 75), turn: 1, statusMs: ago(minutes: 48)),
            DemoTerminal(
                address: "t13", argv: ["bash"], cwd: infra,
                foreground: .init(pid: 27_300, name: "bash", argv: ["bash"], cwd: infra),
                createdMs: ago(minutes: 140)),
        ]
    }

    private static var winbookTerminals: [DemoTerminal] {
        [
            DemoTerminal(
                address: "t21", argv: ["agy"], cwd: DemoBeat.windowsWebsite, title: "agy",
                status: .init(state: "idle", app: "antigravity", title: "Fix flaky checkout test",
                              msg: "Passes 50 runs in a row"),
                labels: seen(2),
                foreground: .init(pid: 9_412, name: "agy", argv: ["agy"], cwd: DemoBeat.windowsWebsite),
                createdMs: ago(minutes: 190), turn: 2, statusMs: ago(minutes: 125)),
        ]
    }

    /// herdr-app's layout document: one space per project.
    static func layout(_ machine: DemoMachine = .studio) -> String {
        switch machine {
        case .studio: """
            {"spaces":[\
            {"id":"spdemowebsite","name":"website","folder":"\(website)","tabs":[\
            {"id":"tbdemo1","name":"","root":{"children":[{"content":{"terminal":"t1"}},{"content":{"terminal":"t4"}}]}}]},\
            {"id":"spdemoshopapi","name":"shop-api","folder":"\(shopAPI)","tabs":[\
            {"id":"tbdemo2","name":"orders","root":{"children":[{"content":{"terminal":"t3"}},{"content":{"terminal":"t7"}}]}},\
            {"id":"tbdemo3","name":"git","root":{"content":{"terminal":"t5"}}}]}]}
            """
        case .buildbox: """
            {"spaces":[\
            {"id":"spdemoinfra","name":"infra","folder":"\(infra)","tabs":[\
            {"id":"tbdemo4","name":"","root":{"children":[{"content":{"terminal":"t11"}},{"content":{"terminal":"t13"}}]}}]},\
            {"id":"spdemocache","name":"shop-api","folder":"\(cacheWorktree)","tabs":[\
            {"id":"tbdemo5","name":"cache","root":{"content":{"terminal":"t12"}}}]}]}
            """
        case .winbook: #"""
            {"spaces":[{"id":"spdemowin","name":"website","folder":"C:\\Users\\demo\\projects\\website","tabs":[{"id":"tbdemo6","name":"","root":{"content":{"terminal":"t21"}}}]}]}
            """#
        }
    }

    static let templates = """
        {"templates":[\
        {"name":"reviewer","description":"Reviews the current branch and leaves notes","command":"agent --role reviewer"},\
        {"name":"fixer","description":"Fixes failing tests","command":"agent --role fixer"}]}
        """

    /// Status changes over the first minute, so the list visibly lives: one agent is at work, and
    /// finishes.
    struct Step: Sendable {
        let at: Duration
        let address: String
        let status: DemoStatus?
    }

    static func timeline(_ machine: DemoMachine = .studio) -> [Step] {
        guard machine == .buildbox else { return [] }
        func working(_ msg: String, _ progress: Int) -> DemoStatus {
            .init(state: "working", app: "codex", title: "Upgrade Postgres to 18", msg: msg, progress: progress)
        }
        return [
            Step(at: .seconds(16), address: "t11", status: working(DemoBeat.upgradeRunning, 70)),
            Step(at: .seconds(28), address: "t11", status: working(DemoBeat.upgradeTests, 88)),
            Step(at: .seconds(42), address: "t11", status: .init(
                state: "done", app: "codex", title: "Upgraded Postgres to 18", msg: DemoBeat.upgradeDone)),
        ]
    }

    // MARK: Screens

    /// A permission prompt as an agent draws it: what it wants to run, the question, and numbered
    /// answers with the cursor on one.
    struct Prompt: Sendable, Equatable {
        var command: String
        var question: String
        var options: [String]

        func paint(selected: Int) -> String {
            var out = [dim(String(repeating: "─", count: 42)), " " + bold("Bash command"), "", " " + command, "",
                       " " + question]
            for (i, option) in options.enumerated() {
                out.append(i == selected ? " " + cyan("❯ \(i + 1). \(option)") : "   \(i + 1). \(option)")
            }
            return out.joined(separator: "\r\n") + "\r\n"
        }
    }

    static let migrationPrompt = Prompt(
        command: DemoBeat.migrationCommand, question: DemoBeat.migrationQuestion,
        options: ["Yes", "Yes, and don't ask again", "No"])
    static let dropPrompt = Prompt(
        command: DemoBeat.dropCommand, question: DemoBeat.dropQuestion, options: ["Yes", "No"])

    enum Role: Sendable {
        /// A small shell that answers a few commands.
        case shell(history: String, cwd: String)
        /// An agent waiting for the next message.
        case agent(String)
        /// The blocked agent asking for permission: what is above the prompt, the prompt, and the
        /// answer the cursor is on.
        case approval(history: String, prompt: Prompt, selected: Int)
        /// Output that keeps coming (tests, a dev server).
        case stream(paint: String, lines: [String], interval: Duration)

        var paint: String {
            switch self {
            case .shell(let history, _): history + prompt
            case .agent(let text): text + prompt
            case .approval(let history, let prompt, let selected): history + prompt.paint(selected: selected)
            case .stream(let paint, _, _): paint
            }
        }

        var prompt: String {
            switch self {
            case .shell(_, let cwd): blue(shortPath(cwd)) + " " + magenta("❯") + " "
            case .agent: "\r\n" + cyan("› ")
            case .approval, .stream: ""
            }
        }
    }

    static func roles(_ machine: DemoMachine = .studio) -> [String: Role] {
        switch machine {
        case .studio: [
            "t1": .agent(websiteAgent),
            "t2": .stream(paint: testsPaint, lines: testsLines, interval: .milliseconds(1500)),
            "t3": .approval(history: totalsAgent, prompt: migrationPrompt, selected: 0),
            "t4": .stream(paint: devServerPaint, lines: devServerLines, interval: .seconds(4)),
            "t5": .shell(history: shellHistory, cwd: shopAPI),
        ]
        case .buildbox: [
            "t11": .agent(infraAgent),
            "t12": .agent(cacheAgent),
            "t13": .shell(history: "", cwd: infra),
        ]
        case .winbook: ["t21": .agent(flakyAgent)]
        }
    }

    static let clear = "\u{1b}[H\u{1b}[2J"

    private static func lines(_ lines: String...) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    static let websiteAgent = lines(
        bold("● agent") + dim(" · website"),
        "",
        cyan("› ") + "Add a dark mode toggle to the header.",
        "",
        "  " + green("✓") + " Theme tokens for both appearances",
        "  " + green("✓") + " ThemeToggle in the header",
        "  " + green("✓") + " Header snapshot updated",
        "  " + green("✓") + " 48 tests pass, build succeeds",
        "",
        "  " + dim("src/components/Header.tsx"),
        "  " + red("-   <CartButton count={count} />"),
        "  " + green("+   <ThemeToggle />"),
        "  " + green("+   <CartButton count={count} />"),
        "",
        "  Dark mode toggle is ready. It follows",
        "  the system setting by default.")

    static let totalsAgent = lines(
        bold("● agent") + dim(" · shop-api"),
        "",
        cyan("› ") + "Add an endpoint for order totals.",
        "",
        "  " + green("✓") + " Wrote src/routes/orderTotals.ts",
        "  " + green("✓") + " Wrote migrations/0043_order_totals",
        "  " + green("✓") + " 6 new tests pass",
        "",
        "  The endpoint needs a new column, so",
        "  the migration has to run first.",
        "")

    static let approved = "\r\n  " + green("✓ Allowed") + "\r\n\r\n"
    static let denied = "\r\n  Skipped. The migration is ready for\r\n  you to run yourself.\r\n"

    static let migrationOutput = [
        dim("  > shop-api@2.3.0 migrate") + "\r\n",
        "  applying 0043_order_totals … " + green("ok") + "\r\n",
        "  backfilling 18,204 orders … " + green("ok") + "\r\n",
    ]

    static let migrationDone = "\r\n  " + green("✓ Migration applied.") + "\r\n  Nothing reads order_totals_old any\r\n  more.\r\n\r\n"

    static let dropDone = "\r\n  " + green("✓ Dropped order_totals_old.") + "\r\n  GET /orders/:id/totals is live.\r\n"
    static let dropKept = "\r\n  Kept order_totals_old. The endpoint\r\n  is live either way.\r\n"

    static let infraAgent = lines(
        bold("● agent") + dim(" · infra"),
        "",
        cyan("› ") + "Upgrade the staging database to",
        "  Postgres 18 and make sure nothing",
        "  breaks.",
        "",
        "  " + green("✓") + " Dumped the cluster (pre-18.sql)",
        "  " + yellow("◐") + " pg_upgrade --check",
        "  " + dim("○ Upgrade with --link"),
        "  " + dim("○ Run the test suite"),
        "",
        yellow("⠹") + " Working · 2 sub-agents")

    static let cacheAgent = lines(
        bold("● agent") + dim(" · shop-api"),
        "",
        cyan("› ") + "Cache product images so the catalog",
        "  page stops refetching them.",
        "",
        "  " + green("✓") + " Measured: 212 image requests a page",
        "  " + green("✓") + " Added an ImageCache interface",
        "",
        "  " + dim("On disk · In Redis"),
        "",
        "  " + bold("Re: " + DemoBeat.cacheQuestion))

    static func cacheAnswered(_ answer: String) -> String {
        "  " + green("✓") + " " + String(answer.prefix(38)) + "\r\n  Wiring the cache in…\r\n"
    }

    static let cacheReady = "  " + green("✓") + " 3 tests pass\r\n\r\n  Done. A second visit makes 4 image\r\n  requests instead of 212.\r\n"

    static let flakyAgent = lines(
        bold("● agent") + dim(" · website"),
        "",
        cyan("› ") + "The checkout test fails about one",
        "  run in ten. Find out why.",
        "",
        "  " + green("✓") + " Reproduced with --repeat 50",
        "  " + green("✓") + " Awaited the payment mock",
        "  " + green("✓") + " 50 of 50 runs pass",
        "",
        "  Done. The test raced the mock.")

    static func newAgentPaint(task: String) -> String {
        lines(
            bold("● agent"),
            "",
            cyan("› ") + (task.isEmpty ? "(no task yet)" : task),
            "",
            "  " + dim("This is the demo machine, so no"),
            "  " + dim("agent really starts here."))
    }

    static let agentReply = lines(
        "  " + dim("I'm a demo agent and can't do real"),
        "  " + dim("work. Add a machine that runs"),
        "  " + dim("herdr-core to talk to your own agents."))

    static let testsPaint = lines(
        dim("> website@1.4.0 test"),
        dim("> vitest --watch"),
        "",
        " " + green("✓") + " src/theme/tokens.test.ts " + dim("(6)"),
        " " + green("✓") + " src/settings/Toggle.test.tsx " + dim("(9)"),
        " " + green("✓") + " src/api/client.test.ts " + dim("(12)"))

    static let testsLines = [
        " " + green("✓") + " src/settings/Profile.test.tsx " + dim("(4)") + "\r\n",
        " " + green("✓") + " src/styles/contrast.test.ts " + dim("(7)") + "\r\n",
        " " + green("✓") + " src/cart/total.test.ts " + dim("(10)") + "\r\n",
        "\r\n Test Files  " + green("8 passed") + " (8)\r\n      Tests  " + green("48 passed") + " (48)\r\n\r\n"
            + dim(" Waiting for file changes…") + "\r\n\r\n",
        " " + cyan("RERUN") + " src/styles/buttons.css\r\n\r\n",
    ]

    static let devServerPaint = lines(
        dim("> website@1.4.0 dev"),
        dim("> vite"),
        "",
        "  " + green(bold("VITE")) + " ready in 412 ms",
        "",
        "  " + green("➜") + "  Local:   " + cyan("http://localhost:5173/"),
        "  " + green("➜") + "  " + dim("Network: use --host to expose"),
        "")

    static let devServerLines = [
        dim("10:42:07") + " " + cyan("[vite]") + " hmr update buttons.css\r\n",
        dim("10:42:11") + " " + cyan("[vite]") + " hmr update Toggle.tsx\r\n",
        dim("10:42:19") + " " + cyan("[vite]") + " page reload theme.css\r\n",
    ]

    static let shellHistory = blue("~/projects/shop-api") + " " + magenta("❯") + " git log --oneline\r\n"
        + lines(
            yellow("a41c9e2") + " Add coupon codes to checkout",
            yellow("7d03b1f") + " Cache product images",
            yellow("2f9e8aa") + " Fix rounding in tax calculation",
            yellow("c19b4d0") + " Update dependencies")

    /// The demo shell's answers.
    static func shell(_ command: String, cwd: String) -> String {
        let word = command.split(separator: " ").first.map(String.init) ?? ""
        switch word {
        case "":
            return ""
        case "help":
            return lines(
                "This is Bergr's demo machine. Try",
                "ls, pwd, git status, git log, echo,",
                "date, clear or exit.",
                "Add a machine that runs herdr-core",
                "to see your own terminals.")
        case "ls":
            return blue("migrations") + "  " + blue("src") + "  " + blue("tests") + "  package.json  README.md\r\n"
        case "pwd":
            return cwd + "\r\n"
        case "whoami":
            return "demo\r\n"
        case "date":
            return Date().formatted(date: .complete, time: .standard) + "\r\n"
        case "echo":
            return String(command.dropFirst(4).drop { $0 == " " }) + "\r\n"
        case "git":
            if command.contains("status") {
                return lines("On branch " + green("main"), "nothing to commit, working tree clean")
            }
            if command.contains("log") {
                return lines(
                    yellow("a41c9e2") + " Add coupon codes to checkout",
                    yellow("7d03b1f") + " Cache product images",
                    yellow("2f9e8aa") + " Fix rounding in tax calculation",
                    yellow("c19b4d0") + " Update dependencies")
            }
            return "git: this demo knows status and log\r\n"
        default:
            return "zsh: command not found: \(word)\r\n" + dim("(demo machine: try help)") + "\r\n"
        }
    }

    // MARK: Styling

    static func shortPath(_ path: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func bold(_ s: String) -> String { "\u{1b}[1m\(s)\u{1b}[22m" }
    static func dim(_ s: String) -> String { "\u{1b}[2m\(s)\u{1b}[22m" }
    static func red(_ s: String) -> String { "\u{1b}[31m\(s)\u{1b}[39m" }
    static func green(_ s: String) -> String { "\u{1b}[32m\(s)\u{1b}[39m" }
    static func yellow(_ s: String) -> String { "\u{1b}[33m\(s)\u{1b}[39m" }
    static func blue(_ s: String) -> String { "\u{1b}[34m\(s)\u{1b}[39m" }
    static func magenta(_ s: String) -> String { "\u{1b}[35m\(s)\u{1b}[39m" }
    static func cyan(_ s: String) -> String { "\u{1b}[36m\(s)\u{1b}[39m" }
}
