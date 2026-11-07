import Foundation

/// What the demo machine shows: three projects with agents, tests, a dev server and a shell.
/// Lines stay under ~44 columns so screens read well on a folded phone.
enum DemoScript {
    static let home = "/Users/demo"
    static let website = home + "/projects/website"
    static let shopAPI = home + "/projects/shop-api"
    static let infra = home + "/projects/infra"

    static let now = UInt64(Date().timeIntervalSince1970 * 1000)

    private static func ago(minutes: UInt64) -> UInt64 { now - minutes * 60_000 }

    /// herdr's shared read state: the last turn someone looked at.
    private static func seen(_ turn: UInt64) -> [String: String] { [Terminal.seenLabel: String(turn)] }

    // MARK: Terminals

    static func terminals() -> [DemoTerminal] {
        [
            DemoTerminal(
                address: "t1", argv: ["agent"], cwd: website, title: "agent",
                status: .init(state: "working", app: "agent", title: "Adding a dark mode toggle",
                              msg: "Updating styles (12 of 20 files)", progress: 60),
                labels: seen(2), foreground: .init(pid: 31_201, name: "agent", argv: ["agent"], cwd: website),
                createdMs: ago(minutes: 18), turn: 2, statusMs: ago(minutes: 6)),
            DemoTerminal(
                address: "t2", name: "tests", argv: ["npm", "test", "--", "--watch"], cwd: website,
                status: .init(state: "working", app: "tests", title: "Running tests", msg: "31 of 48 passed", progress: 65),
                labels: seen(0), foreground: .init(pid: 31_377, name: "node", argv: ["node", "vitest", "--watch"], cwd: website),
                createdMs: ago(minutes: 3), parent: "t1", statusMs: ago(minutes: 3)),
            DemoTerminal(
                address: "t3", argv: ["agent"], cwd: shopAPI, title: "agent",
                status: .init(state: "blocked", app: "agent", title: "Run the database migration?",
                              msg: "npm run migrate", kind: "permission"),
                labels: seen(1), foreground: .init(pid: 30_822, name: "agent", argv: ["agent"], cwd: shopAPI),
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
                address: "t6", argv: ["agent"], cwd: infra, title: "agent",
                status: .init(state: "done", app: "agent", title: "Upgraded Postgres to 18", msg: "All checks green"),
                // Finished a turn nobody has looked at yet.
                labels: seen(2), foreground: .init(pid: 28_456, name: "agent", argv: ["agent"], cwd: infra),
                createdMs: ago(minutes: 130), turn: 3, statusMs: ago(minutes: 47)),
            DemoTerminal(
                address: "t7", name: "nightly-backup", argv: ["./backup.sh"], cwd: infra, state: "finished",
                createdMs: ago(minutes: 300), exitCode: 0, reason: "exited"),
        ]
    }

    /// herdr-app's layout document: one space per project.
    static let layout = """
        {"spaces":[\
        {"id":"spdemowebsite","name":"website","folder":"\(website)","tabs":[\
        {"id":"tbdemo1","name":"","root":{"children":[{"content":{"terminal":"t1"}},{"content":{"terminal":"t4"}}]}}]},\
        {"id":"spdemoshopapi","name":"shop-api","folder":"\(shopAPI)","tabs":[\
        {"id":"tbdemo2","name":"orders","root":{"content":{"terminal":"t3"}}},\
        {"id":"tbdemo3","name":"git","root":{"content":{"terminal":"t5"}}}]},\
        {"id":"spdemoinfra","name":"infra","folder":"\(infra)","tabs":[\
        {"id":"tbdemo4","name":"","root":{"children":[{"content":{"terminal":"t6"}},{"content":{"terminal":"t7"}}]}}]}]}
        """

    static let templates = """
        {"templates":[\
        {"name":"reviewer","description":"Reviews the current branch and leaves notes","command":"agent --role reviewer"},\
        {"name":"fixer","description":"Fixes failing tests","command":"agent --role fixer"}]}
        """

    /// Status changes over the first minute, so the list visibly lives.
    struct Step: Sendable {
        let at: Duration
        let address: String
        let status: DemoStatus?
    }

    static let timeline: [Step] = [
        Step(at: .seconds(4), address: "t2", status: .init(
            state: "working", app: "tests", title: "Running tests", msg: "44 of 48 passed", progress: 90)),
        Step(at: .seconds(8), address: "t2", status: .init(
            state: "done", app: "tests", title: "Tests passed", msg: "48 passed")),
        Step(at: .seconds(12), address: "t1", status: .init(
            state: "working", app: "agent", title: "Adding a dark mode toggle",
            msg: "Updating styles (16 of 20 files)", progress: 75)),
        Step(at: .seconds(24), address: "t1", status: .init(
            state: "working", app: "agent", title: "Adding a dark mode toggle", msg: "Checking contrast", progress: 90)),
        Step(at: .seconds(40), address: "t1", status: .init(
            state: "done", app: "agent", title: "Dark mode toggle ready", msg: "20 files changed")),
    ]

    // MARK: Screens

    enum Role: Sendable {
        /// A small shell that answers a few commands.
        case shell(history: String, cwd: String)
        /// An agent waiting for the next message.
        case agent(String)
        /// The blocked agent asking for permission.
        case approval
        /// Output that keeps coming (tests, a dev server).
        case stream(paint: String, lines: [String], interval: Duration)

        var paint: String {
            switch self {
            case .shell(let history, _): history + prompt
            case .agent(let text): text + prompt
            case .approval: approvalPaint
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

    static let roles: [String: Role] = [
        "t1": .agent(websiteAgent),
        "t2": .stream(paint: testsPaint, lines: testsLines, interval: .milliseconds(1500)),
        "t3": .approval,
        "t4": .stream(paint: devServerPaint, lines: devServerLines, interval: .seconds(4)),
        "t5": .shell(history: shellHistory, cwd: shopAPI),
        "t6": .agent(infraAgent),
    ]

    static let clear = "\u{1b}[H\u{1b}[2J"

    private static func lines(_ lines: String...) -> String {
        lines.joined(separator: "\r\n") + "\r\n"
    }

    static let websiteAgent = lines(
        bold("● agent") + dim(" · website"),
        "",
        cyan("› ") + "Add a dark mode toggle to the",
        "  settings page. Keep the colors we",
        "  already use.",
        "",
        "  Read src/settings/*.tsx and",
        "  src/styles/theme.css.",
        "",
        "  " + green("✓") + " Dark tokens for --bg and --fg",
        "  " + green("✓") + " ThemeToggle component",
        "  " + yellow("◐") + " Updating styles (12 of 20)",
        "  " + dim("○ Run the tests"),
        "",
        "  " + dim("src/styles/buttons.css"),
        "  " + red("- background: #ffffff;"),
        "  " + green("+ background: var(--bg);"),
        "  " + red("- color: #1f2124;"),
        "  " + green("+ color: var(--fg);"),
        "",
        yellow("⠹") + " Working · tests run in t2")

    static let approvalPaint = lines(
        bold("● agent") + dim(" · shop-api"),
        "",
        cyan("› ") + "Add a total_cents column to orders",
        "  and backfill it from the line items.",
        "",
        "  " + green("✓") + " Wrote migrations/0042_total.sql",
        "  " + green("✓") + " Updated src/orders/model.ts",
        "",
        "  Next I want to run:",
        "    " + bold("npm run migrate"),
        "")
        + "  " + bold(yellow("Allow? [y/n] "))

    static let approved = "y\r\n  " + green("✓ Allowed") + "\r\n\r\n"
    static let denied = "n\r\n  Skipped. The migration is ready for\r\n  you to run yourself.\r\n"

    static let migrationOutput = [
        dim("  > shop-api@2.3.0 migrate") + "\r\n",
        "  applying 0042_total … " + green("ok") + "\r\n",
        "  backfilling 18,204 orders … " + green("ok") + "\r\n",
    ]

    static let migrationDone = "\r\n  " + green("✓ Migration applied.") + "\r\n  orders.total_cents is filled in.\r\n"

    static let infraAgent = lines(
        bold("● agent") + dim(" · infra"),
        "",
        cyan("› ") + "Upgrade the database to Postgres 18.",
        "",
        "  " + green("✓") + " Took a snapshot (db-2026-11-02)",
        "  " + green("✓") + " Upgraded staging, ran smoke tests",
        "  " + green("✓") + " Upgraded production",
        "  " + green("✓") + " All checks green",
        "",
        "  Done. Postgres 18.1 runs on both.")

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
            yellow("a41c9e2") + " Add order totals endpoint",
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
                    yellow("a41c9e2") + " Add order totals endpoint",
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
