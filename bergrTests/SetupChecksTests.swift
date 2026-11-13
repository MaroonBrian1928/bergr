import Foundation
import Testing
@testable import bergr

struct SetupNewChecksTests {
    // MARK: git

    @Test func gitVersionParsed() {
        #expect(SetupCheck.parseGit("Darwin\ngit version 2.39.3 (Apple Git-145)\n") == "2.39.3")
        #expect(SetupCheck.parseGit("git version 2.45.0.windows.1") == "2.45.0")
    }

    @Test func gitMissing() {
        #expect(SetupCheck.parseGit("Linux\nsh: 1: git: not found\n") == nil)
        #expect(SetupCheck.parseGit("Darwin\nmissing\n") == nil)
        #expect(SetupCheck.parseGit("") == nil)
    }

    @Test func gitCommandAvoidsTheMacStub() {
        let command = SetupCheck.gitCommand(windows: false)
        #expect(command.contains("xcode-select -p"))
        #expect(command.hasPrefix("export PATH") && command.contains("uname -s"))
    }

    @Test func hostOSFromUname() {
        #expect(SetupCheck.parseOS("Darwin\ngit version 2\n") == .mac)
        #expect(SetupCheck.parseOS("Linux\n") == .linux)
        #expect(SetupCheck.parseOS("") == nil)
    }

    // MARK: sleep

    private let pmsetSleeps = """
    darwin
    Battery Power:
     lidwake              1
     sleep                1
     displaysleep         2
    AC Power:
     lidwake              1
     displaysleep         10
     sleep                15
     disksleep            10
    """

    @Test func macSleepsOnAC() {
        #expect(SetupCheck.parseSleep(pmsetSleeps) == .sleeps(minutes: 15))
    }

    @Test func macStaysAwakeOnAC() {
        let output = pmsetSleeps.replacingOccurrences(of: "sleep                15", with: "sleep                0")
        #expect(SetupCheck.parseSleep(output) == .staysAwake)
    }

    @Test func macIgnoresBatterySectionAndDisplaySleep() {
        let output = "darwin\nBattery Power:\n sleep 1\nAC Power:\n displaysleep 10\n"
        #expect(SetupCheck.parseSleep(output) == .unknown)
    }

    @Test func linuxMaskedTargetsStayAwake() {
        #expect(SetupCheck.parseSleep("linux\nmasked\nmasked\n") == .staysAwake)
    }

    @Test func linuxUnmaskedTargetsSleep() {
        #expect(SetupCheck.parseSleep("linux\nstatic\nstatic\n") == .sleeps(minutes: nil))
    }

    @Test func linuxWithoutSystemdIsUnknown() {
        #expect(SetupCheck.parseSleep("linux\nsh: 1: systemctl: not found\n") == .unknown)
        #expect(SetupCheck.parseSleep("") == .unknown)
    }

    @Test func sleepIsAWarningNotAnError() {
        if case .warning(let text) = SetupCheck.sleepState(.sleeps(minutes: 15)) {
            #expect(text.contains("15 min"))
        } else {
            Issue.record("expected a warning")
        }
        #expect(SetupCheck.sleepState(.staysAwake) == .ready("Stays awake on power"))
    }

    // MARK: core version

    @Test func versionComparison() {
        #expect(SetupCheck.isOlder("0.1.15", than: "0.1.16"))
        #expect(!SetupCheck.isOlder("0.1.16", than: "0.1.16"))
        #expect(!SetupCheck.isOlder("0.1.20", than: "0.1.16"))
        #expect(!SetupCheck.isOlder("0.2", than: "0.1.16"))
        #expect(SetupCheck.isOlder("v0.1", than: "0.1.16"))
        #expect(!SetupCheck.isOlder("0.1.20-beta", than: "0.1.16"))
        #expect(!SetupCheck.isOlder("garbage", than: "0.1.16"))
    }

    @Test func coreStateAgainstTheMinimum() {
        #expect(SetupCheck.coreState(version: nil) == .ready("running"))
        #expect(SetupCheck.coreState(version: "0.1.20") == .ready("version 0.1.20"))
        if case .outdated(let text) = SetupCheck.coreState(version: "0.1.10") {
            #expect(text.contains(SetupCheck.minimumCoreVersion))
        } else {
            Issue.record("expected outdated")
        }
    }

    // MARK: signed in

    @Test func claudeSignedIn() {
        let on = "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\"\n}"
        let off = "{\n  \"loggedIn\": false\n}"
        #expect(SetupCheck.parseSignedIn(.claude, output: on) == true)
        #expect(SetupCheck.parseSignedIn(.claude, output: off) == false)
        #expect(SetupCheck.parseSignedIn(.claude, output: "error: unknown command 'auth'") == nil)
        #expect(SetupCheck.parseSignedIn(.claude, output: "") == nil)
    }

    @Test func codexSignedIn() {
        #expect(SetupCheck.parseSignedIn(.codex, output: "Logged in using ChatGPT\n") == true)
        #expect(SetupCheck.parseSignedIn(.codex, output: "Not logged in\n") == false)
        #expect(SetupCheck.parseSignedIn(.codex, output: "error: unrecognized subcommand 'status'") == nil)
    }

    @Test func antigravityIsSkipped() {
        #expect(SetupCheck.signInCommand(.antigravity, windows: false) == nil)
        #expect(SetupCheck.parseSignedIn(.antigravity, output: "Logged in") == nil)
        #expect(AgentCLI.antigravity.installCommand(windows: false) == nil)
    }

    @Test func signInProbesAreNonInteractive() {
        let claude = SetupCheck.signInCommand(.claude, windows: false) ?? ""
        let codex = SetupCheck.signInCommand(.codex, windows: false) ?? ""
        #expect(claude.contains("claude auth status </dev/null"))
        #expect(codex.contains("codex login status </dev/null"))
    }

    // MARK: install commands and fixes

    @Test func officialInstallCommands() {
        #expect(AgentCLI.claude.installCommand(windows: false) == "curl -fsSL https://claude.ai/install.sh | bash")
        #expect(AgentCLI.claude.installCommand(windows: true) == "irm https://claude.ai/install.ps1 | iex")
        #expect(AgentCLI.codex.installCommand(windows: false) == "npm install -g @openai/codex")
    }

    @Test func fixesThatNeedSudoOrPromptsAreNotRunnable() {
        #expect(SetupCheck.gitFix(os: .mac)?.runnable == false)
        #expect(SetupCheck.gitFix(os: .linux)?.runnable == false)
        #expect(SetupCheck.sleepFix(os: .mac)?.command == "sudo pmset -c sleep 0")
        #expect(SetupCheck.sleepFix(os: .linux)?.runnable == false)
        #expect(SetupCheck.installFix(.claude, windows: false)?.runnable == true)
        // PowerShell's installer can't go through the cmd exec channel.
        #expect(SetupCheck.installFix(.claude, windows: true)?.runnable == false)
        #expect(SetupCheck.installFix(.antigravity, windows: false) == nil)
    }
}

@MainActor
struct SetupRepairTests {
    private let fix = SetupFix(command: "echo hi", runnable: true)
    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    @Test func outputIsParsedForExitAndTail() {
        let out = "one\ntwo\nthree\nfour\nfive\nsix\nseven\n__bergr_exit=3\n"
        let parsed = SetupRepair.parse(out, tailLines: 3)
        #expect(parsed.exit == 3)
        #expect(parsed.tail == "five\nsix\nseven")
        #expect(SetupRepair.parse("plain").exit == nil)
    }

    @Test func wrapsWithStderrAndExitStatus() {
        let wrapped = SetupRepair.wrap("curl x | bash")
        #expect(wrapped.contains("curl x | bash") && wrapped.contains("2>&1") && wrapped.contains("__bergr_exit=$?"))
    }

    @Test func runsThenRechecksAndClears() async {
        let repair = SetupRepair()
        var ran: String?
        var rechecked = 0
        let ok = await repair.run("a", fix: fix, execute: { ran = $0; return "done\n__bergr_exit=0\n" },
                                  recheck: { rechecked += 1; return true })
        #expect(ok)
        #expect(ran?.contains("echo hi") == true)
        #expect(rechecked == 1)
        #expect(repair.states["a"] == nil)
    }

    @Test func showsFailureWithOutputTailWhenCheckStillFails() async {
        let repair = SetupRepair()
        let ok = await repair.run("a", fix: fix,
                                  execute: { _ in "npm ERR! EACCES\n__bergr_exit=243\n" }, recheck: { false })
        #expect(!ok)
        guard case .failed(let text) = repair.states["a"] else { Issue.record("expected failure"); return }
        #expect(text.contains("status 243") && text.contains("EACCES"))
    }

    @Test func rechecksEvenWhenTheRunnerThrows() async {
        let repair = SetupRepair()
        var rechecked = false
        let ok = await repair.run("a", fix: fix, execute: { _ in throw Boom() }, recheck: { rechecked = true; return false })
        #expect(!ok && rechecked)
        guard case .failed(let text) = repair.states["a"] else { Issue.record("expected failure"); return }
        #expect(text.contains("boom"))
    }

    @Test func succeedsWhenCheckPassesDespiteNonzeroExit() async {
        let repair = SetupRepair()
        let ok = await repair.run("a", fix: fix, execute: { _ in "__bergr_exit=1\n" }, recheck: { true })
        #expect(ok && repair.states["a"] == nil)
    }

    @Test func runningStateBlocksASecondRun() async {
        let repair = SetupRepair()
        var seen: SetupRepair.State?
        await repair.run("a", fix: fix, execute: { _ in
            seen = repair.states["a"]
            let second = await repair.run("a", fix: fix, execute: { _ in "x" }, recheck: { true })
            #expect(!second)
            return ""
        }, recheck: { true })
        #expect(seen == .running)
    }

    @Test func aFailedRunCanBeRetried() async {
        let repair = SetupRepair()
        await repair.run("a", fix: fix, execute: { _ in "" }, recheck: { false })
        let ok = await repair.run("a", fix: fix, execute: { _ in "" }, recheck: { true })
        #expect(ok && repair.states["a"] == nil)
    }
}
