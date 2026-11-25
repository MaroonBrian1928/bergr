import Foundation
import SSHTransport
import HerdrKit
import Testing
@testable import bergr

struct AnswerCardTests {
    static let claude = [
        "● Running git push",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for git commands in /home/x",
        "   3. No, and tell Claude what to do differently (esc)",
    ]
    static let boxed = [
        "╭──────────────────╮",
        "│ Do you want to proceed? │",
        "│ ❯ 1. Yes                │",
        "│   2. No                 │",
        "╰──────────────────╯",
    ]
    static let codex = [
        "  Allow command?",
        "",
        "  › 1. Yes, proceed (y)",
        "    2. Yes, and don't ask again for this command (a)",
        "    3. No, and tell Codex what to do differently (esc)",
    ]

    @Test func claudeAskUserQuestionWithRuleAndDescriptions() {
        let lines = [
            " ☐ Screen test",
            "",
            "│ Test question so I can capture how it looks on screen.",
            "",
            "❯ 1. Done (Recommended)",
            "     The capture has had time to run.",
            "  2. Other choice",
            "     Also fine; any answer works.",
            "  3. Type something.",
            "────────────────────────────────────────",
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        let choices = AnswerParser.choices(in: lines)
        #expect(choices.map(\.number) == [1, 2, 3, 4])
        #expect(choices.first?.selected == true)
    }

    /// On a phone-width terminal an option's description wraps over many lines.
    @Test func claudeQuestionWithLongWrappedDescriptions() {
        let lines = [
            "│ Where should reports land?",
            "",
            "❯ 1. Relay to GitHub issue (Recommended)",
            "     The relay files each report as an issue",
            "     in a private repo, with the log and the",
            "     screenshot attached. You get GitHub's",
            "     notifications, a searchable list and",
            "     comments. Needs a GitHub token stored",
            "  2. Relay to R2 and push to me",
            "     Reports are kept in R2 for 30 days and",
            "     an alert is pushed to your phone. You",
            "     read them on a small private page.",
            "  3. Type something.",
            "────────────────────────────────",
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        #expect(AnswerParser.choices(in: lines).map(\.number) == [1, 2, 3, 4])
    }

    // A Claude question on a phone-width terminal: the question wraps, each option has a description.
    @Test func claudeQuestionWrapsAndDescribes() {
        let lines = [
            "────────────────────────────────",
            " ☐ Icon",
            "",
            "Second Wind's app icon (page just opened): which",
            "one ships?",
            "",
            "❯ 1. C, Plate in the Wind (Recommended)",
            "     A weight plate trailing gusts: lifting and run…",
            "  2. D, Second Swell",
            "     Two full-bleed swells, t…",
            "  3. Type something.",
            "────────────────────────────────",
            "  4. Chat about this",
        ]
        #expect(AnswerParser.question(in: lines) == "Second Wind's app icon (page just opened): which one ships?")
        #expect(AnswerParser.context(in: lines) == ["☐ Icon"])
        let c = AnswerParser.choices(in: lines)
        #expect(c.map(\.label) == ["C, Plate in the Wind (Recommended)", "D, Second Swell", "Type something.", "Chat about this"])
        #expect(c[0].detail == "A weight plate trailing gusts: lifting and run…")
        #expect(c[2].detail.isEmpty)
    }

    @Test func claudePrompt() {
        let c = AnswerParser.choices(in: Self.claude)
        #expect(c.map(\.number) == [1, 2, 3])
        #expect(c.map(\.selected) == [true, false, false])
        #expect(c[0].label == "Yes")
        #expect(AnswerParser.question(in: Self.claude) == "Do you want to proceed?")
    }

    @Test func boxedPrompt() {
        let c = AnswerParser.choices(in: Self.boxed)
        #expect(c == [AnswerChoice(number: 1, label: "Yes", selected: true), AnswerChoice(number: 2, label: "No", selected: false)])
        #expect(AnswerParser.question(in: Self.boxed) == "Do you want to proceed?")
    }

    @Test func codexPrompt() {
        let c = AnswerParser.choices(in: Self.codex)
        #expect(c.map(\.number) == [1, 2, 3])
        #expect(c[0].selected && !c[1].selected)
        #expect(c[0].label == "Yes, proceed (y)")
        #expect(AnswerParser.question(in: Self.codex) == "Allow command?")
    }

    @Test func noMarkers() {
        let c = AnswerParser.choices(in: ["Pick?", "1. A", "2. B"])
        #expect(c.map(\.selected) == [false, false])
    }

    @Test func emptyWhenNotStartingAtOneOrNoList() {
        #expect(AnswerParser.choices(in: ["Q", "2. A", "3. B"]).isEmpty)
        #expect(AnswerParser.choices(in: ["just text", "version 1.2"]).isEmpty)
        #expect(AnswerParser.question(in: ["just text"]) == nil)
    }

    @Test func bottomMostListWins() {
        let lines = ["Here are options:", "1. Apples", "2. Pears", "3. Plums", "", "Proceed?", "❯ 1. Yes", "  2. No"]
        #expect(AnswerParser.choices(in: lines).map(\.label) == ["Yes", "No"])
        #expect(AnswerParser.question(in: lines) == "Proceed?")
    }

    @Test func staleQuestionIsDetected() {
        let yes = AnswerChoice(number: 1, label: "Yes", selected: true)
        #expect(AnswerParser.isStillShown(yes, in: Self.claude))
        #expect(!AnswerParser.isStillShown(yes, in: Self.codex))
        #expect(!AnswerParser.isStillShown(yes, in: ["$ ls"]))
        #expect(!AnswerParser.isStillShown(yes, in: ["Q?", "1. Sure", "2. No"]))
    }

    @Test func arrowSteps() {
        let c = AnswerParser.choices(in: ["Q?", "  1. A", "❯ 2. B", "  3. C"])
        #expect(AnswerParser.steps(to: c[0], in: c) == -1)
        #expect(AnswerParser.steps(to: c[2], in: c) == 1)
        #expect(AnswerParser.steps(to: c[1], in: c) == 0)
    }
}

struct AntigravityApprovalTests {
    // Antigravity CLI 1.5.2's command approval on a phone-width terminal (options wrap).
    let screen = [
        "Command",
        "────────────────────────────────────────",
        "",
        "Requesting permission for:",
        "   ls -la /home/me/project",
        "",
        "Run this command?",
        "> 1. Yes, run command",
        "  2. Yes, and always allow in this conversation for",
        "commands that start with 'ls'",
        "  3. Yes, and always allow for commands that start",
        "with 'ls' (Persist to settings.json)",
        "  4. No, cancel",
        "",
        "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand comma",
        "esc to cancel  accept-edits · Gemini 4 Argon · medium",
    ]

    @Test func wrappedOptionsJoin() {
        let choices = AnswerParser.choices(in: screen)
        #expect(choices.map(\.number) == [1, 2, 3, 4])
        #expect(choices[1].label == "Yes, and always allow in this conversation for commands that start with 'ls'")
        #expect(choices[2].label == "Yes, and always allow for commands that start with 'ls' (Persist to settings.json)")
        #expect(choices[0].selected)
    }

    @Test func questionAndContext() {
        #expect(AnswerParser.question(in: screen) == "Run this command?")
        #expect(AnswerParser.context(in: screen) == ["Requesting permission for:", "ls -la /home/me/project"])
    }
}

struct HelperCoversTests {
    @Test func recentHelperSendsTheAlert() {
        #expect(AgentNotifier.helperCovers(age: 60))
        #expect(!AgentNotifier.helperCovers(age: RelayHeard.staleAfter + 1))
        #expect(!AgentNotifier.helperCovers(age: nil))
    }
}

struct LastOptionDetailTests {
    @Test func lastOptionKeepsItsDescription() {
        let lines = ["Pick?", "", "❯ 1. A", "     About A", "  2. B", "     About B", "", "Esc to cancel"]
        let c = AnswerParser.choices(in: lines)
        #expect(c.map(\.label) == ["A", "B"])
        #expect(c.map(\.detail) == ["About A", "About B"])
    }

    @Test func footersStayOut() {
        let indented = ["Pick?", "", "❯ 1. A", "  2. B", "     Enter to select · Esc to cancel"]
        #expect(AnswerParser.choices(in: indented).last?.detail == "")
        let boxed = ["│ Pick?        │", "│ ❯ 1. Yes     │", "│   2. No      │", "│ Esc to cancel │", "╰──────────────╯"]
        #expect(AnswerParser.choices(in: boxed).last?.label == "No")
    }
}

struct LinkedAlsoDirectTests {
    static func machines(_ json: String) throws -> [MachineView] {
        try JSONDecoder().decode([MachineView].self, from: Data(json.utf8))
    }

    @Test func directConnectionWinsByCoreName() throws {
        let linked = try Self.machines(#"[{"name":"studio","host":null,"state":"connected","target":null,"version":null},{"name":"pi","host":null,"state":"connected","target":null,"version":null}]"#)
        let host = Host(name: "Workstation", target: SSHTarget(host: "10.0.0.20", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(linked, names: ["studio", "pi"],
                                             direct: SameMachine.directNames(host, coreName: nil, failed: false)).isEmpty)
        let direct = SameMachine.directNames(host, coreName: "studio", failed: false)
        #expect(SameMachine.linkedAlsoDirect(linked, names: ["studio", "pi"], direct: direct) == ["studio"])
        #expect(SameMachine.directNames(host, coreName: "studio", failed: true) == SameMachine.DirectIdentity())
    }

    @Test func differentMachinesStayApart() throws {
        // Same name, different address: two machines.
        let linked = try Self.machines(#"[{"name":"laptop","host":"10.0.0.9","state":"connected","target":null,"version":null}]"#)
        let host = Host(name: "laptop", target: SSHTarget(host: "10.0.0.5", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(linked, names: ["laptop"],
                                             direct: SameMachine.directNames(host, coreName: "laptop", failed: false)).isEmpty)
        // localhost on two machines is two machines.
        let local = try Self.machines(#"[{"name":"box","host":"localhost","state":"connected","target":null,"version":null}]"#)
        let mine = Host(name: "Mine", target: SSHTarget(host: "localhost", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(local, names: ["box"],
                                             direct: SameMachine.directNames(mine, coreName: nil, failed: false)).isEmpty)
        // A linked "box" at its own localhost isn't the directly added "box".
        let boxHost = Host(name: "box", target: SSHTarget(host: "10.0.0.7", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(local, names: ["box"],
                                             direct: SameMachine.directNames(boxHost, coreName: "box", failed: false)).isEmpty)
        // Same address: one machine, whatever the names.
        let same = try Self.machines(#"[{"name":"lab","host":"10.0.0.5","state":"connected","target":null,"version":null}]"#)
        #expect(SameMachine.linkedAlsoDirect(same, names: ["lab"],
                                             direct: SameMachine.directNames(host, coreName: nil, failed: false)) == ["lab"])
    }

    @Test func targetsCompareByTheirHost() throws {
        #expect(SameMachine.hostPart("alex@10.0.0.21") == "10.0.0.21")
        #expect(SameMachine.hostPart("me@Studio.local:2222") == "studio.local")
        #expect(SameMachine.hostPart("[fe80::1]:22") == "fe80::1")
        #expect(SameMachine.hostPart("fe80::1") == "fe80::1")
        #expect(SameMachine.hostPart("127.0.1.1").isEmpty)
        // herdr writes the target with the user: still the machine saved by its IP.
        let linked = try Self.machines(#"[{"name":"laptop","host":null,"state":"connected","target":"alex@10.0.0.21","version":null}]"#)
        let host = Host(name: "Laptop", target: SSHTarget(host: "10.0.0.21", username: "alex"))
        #expect(SameMachine.linkedAlsoDirect(linked, names: ["laptop"],
                                             direct: SameMachine.directNames(host, coreName: nil, failed: false)) == ["laptop"])
    }

    @Test func aNameAndItsIPAreOneMachine() throws {
        // Saved by name, linked by IP (and the other way round): the lookup ties them together.
        let resolve: (String) -> Set<String> = { $0 == "studio.local" ? ["10.0.0.20"] : [] }
        let byIP = try Self.machines(#"[{"name":"box","host":null,"state":"connected","target":"10.0.0.20","version":null}]"#)
        let byName = Host(name: "Workstation", target: SSHTarget(host: "studio.local", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(byIP, names: ["box"],
                                             direct: SameMachine.directNames(byName, coreName: nil, failed: false, resolve: resolve),
                                             resolve: resolve) == ["box"])
        let linkedByName = try Self.machines(#"[{"name":"box","host":"studio.local","state":"connected","target":null,"version":null}]"#)
        let savedByIP = Host(name: "Workstation", target: SSHTarget(host: "10.0.0.20", username: "me"))
        #expect(SameMachine.linkedAlsoDirect(linkedByName, names: ["box"],
                                             direct: SameMachine.directNames(savedByIP, coreName: nil, failed: false, resolve: resolve),
                                             resolve: resolve) == ["box"])
        // One IP, two SSH ports: two machines behind one router.
        let natLinked = try Self.machines(#"[{"name":"b","host":null,"state":"connected","target":"me@203.0.113.5:2223","version":null}]"#)
        let natHost = Host(name: "A", target: SSHTarget(host: "203.0.113.5", port: 2222, username: "me"))
        #expect(SameMachine.linkedAlsoDirect(natLinked, names: ["b"],
                                             direct: SameMachine.directNames(natHost, coreName: nil, failed: false)).isEmpty)
        #expect(SameMachine.linkedAlsoDirect(natLinked, names: ["b"],
                                             direct: SameMachine.directNames(natHost, coreName: "203.0.113.5", failed: false)).isEmpty)
        let natBoth = try Self.machines(#"[{"name":"b","host":"203.0.113.5","state":"connected","target":"me@203.0.113.5:2223","version":null}]"#)
        #expect(SameMachine.linkedAlsoDirect(natBoth, names: ["b"],
                                             direct: SameMachine.directNames(natHost, coreName: nil, failed: false)).isEmpty)
        // One machine, two users: two cores, two sets of agents.
        let otherUser = try Self.machines(#"[{"name":"root-box","host":null,"state":"connected","target":"root@10.0.0.21","version":null}]"#)
        let alex = Host(name: "Laptop", target: SSHTarget(host: "10.0.0.21", username: "alex"))
        #expect(SameMachine.linkedAlsoDirect(otherUser, names: ["root-box"],
                                             direct: SameMachine.directNames(alex, coreName: nil, failed: false)).isEmpty)
        #expect(SameMachine.hostPart("2001:0db8:0:0:0:0:0:1") == "2001:db8::1")
        #expect(SameMachine.hostPart("0:0:0:0:0:0:0:1").isEmpty)
        #expect(AddressResolver.isIP("10.0.0.20") && AddressResolver.isIP("fe80::1") && !AddressResolver.isIP("studio.local"))
    }

    @Test func descriptionsThatMentionKeysStay() {
        let lines = ["Pick?", "", "❯ 1. A", "  2. B", "     Press Enter to insert a newline", "", "Enter to select · Esc to cancel"]
        #expect(AnswerParser.choices(in: lines).last?.detail == "Press Enter to insert a newline")
    }
}

struct MenuOpenTests {
    static let model = [
        "  Select model",
        "  Your pick is the default for new sessions. For other models, use --model.",
        "    1.  Default (recommended)  Opus 5.5 · Best for everyday, complex tasks",
        "  ❯ 5.  Haiku 5.5 ✔            Fastest for quick answers",
        "  ◐ Medium effort (default) ←/→ to adjust",
        "",
        "  s to use this session only · Enter to save · Esc to cancel",
    ]
    static let permissions = [
        "  Update Model Permissions",
        "  1. Ask for approval          Read and edit workspace files ...",
        "› 2. Approve for me (current)  Only ask for actions detected as potentially unsafe",
        "  3. Full Access               Use with caution ...",
        "",
        "  enter select · esc back",
    ]
    static let idleClaude = ["● Done.", "", "╭────╮", "│ ❯  │", "╰────╯", "  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent"]
    static let idleCodex = ["• Done.", "", "› Ask Codex to do anything", "", "  ← for agents · ? for shortcuts"]

    @Test func detectsMenus() {
        #expect(AnswerParser.menuOpen(Self.model))
        #expect(AnswerParser.menuOpen(Self.permissions))
        #expect(AnswerParser.menuOpen(["  Servers", "  ↑/↓ to navigate · Enter to view · Esc to close"]))
        #expect(AnswerParser.menuOpen(["  Config", "  ↓ to navigate · ↑ to switch tabs · Esc to go back"]))
        #expect(AnswerParser.menuOpen(["  Resume", "  Ctrl+A to show all projects · Ctrl+B to only show current branch · Esc to close"]))
        #expect(AnswerParser.menuOpen([" Resume a chat", " enter resume   esc exit   ^c exit   tab focus sort/filter   ←/→ change option"]))
    }

    @Test func ignoresNormalScreens() {
        #expect(!AnswerParser.menuOpen(Self.idleClaude))
        #expect(!AnswerParser.menuOpen(Self.idleCodex))
        #expect(!AnswerParser.menuOpen(["Steps:", "1. Install", "2. Build", "3. Test", "", "❯ "]))
        #expect(!AnswerParser.menuOpen(["Esc to close"] + Self.idleClaude + ["a", "b"]))
    }

    @Test func title() {
        #expect(AnswerParser.menuTitle(Self.permissions) == "Update Model Permissions")
    }

    /// Claude's /permissions panel on a phone-width terminal (its footer wraps).
    static let claudePermissions = [
        "✻ Crunched for 1m 2s · done 5:06 PM",
        "────────────────────────────────────────",
        "",
        "  Permissions  Recently blocked   Allow   Ask",
        "               Deny   Auto mode   Workspace",
        "",
        "  Commands auto mode recently blocked. Approving",
        "  adds no rule.",
        "",
        "  ❯ 1. ✘ Run commands   Auto mode: [Destructive or",
        "                        Unwanted Actions]",
        "",
        "    ┊ const tomlPath = F+'/wrangler.toml';",
        "    … +27 lines (ctrl+o to see more)",
        "",
        "  ↑/↓ to navigate · r to retry · Enter to approve ·",
        "  Esc to close",
    ]

    @Test func claudePermissionsPanel() {
        #expect(AnswerParser.menuOpen(Self.claudePermissions))
        #expect(AnswerParser.menuTitle(Self.claudePermissions) == "Permissions  Recently blocked   Allow   Ask")
        #expect(AnswerParser.choices(in: Array(Self.claudePermissions.suffix(20))).map(\.number) == [1])
    }
}
