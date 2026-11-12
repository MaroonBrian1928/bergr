import Foundation
import NIOCore
import SSHTransport
import Testing
@testable import bergr

struct SSHConfigTests {
    @Test func readsHostNameUserPortAndIdentity() {
        let entries = SSHConfig.entries("""
        Host web
          HostName web.example.com
          User deploy
          Port 2222
          IdentityFile ~/.ssh/web_ed25519
        """)
        #expect(entries == [SSHConfigEntry(alias: "web", hostName: "web.example.com", user: "deploy",
                                           port: 2222, identityFile: "~/.ssh/web_ed25519")])
    }

    @Test func skipsWildcardAndNegatedPatterns() {
        let entries = SSHConfig.entries("""
        Host *
          User me
        Host *.example.com !bad.example.com
          Port 2200
        Host ?ab
          User x
        Host web
          HostName web.example.com
        """)
        #expect(entries.map(\.alias) == ["web"])
        #expect(entries.first?.user == nil)
    }

    @Test func ignoresInclude() {
        let entries = SSHConfig.entries("""
        Include ~/.ssh/config.d/*
        Host a
          HostName a.example.com
        """)
        #expect(entries.map(\.alias) == ["a"])
    }

    @Test func oneBlockForSeveralAliases() {
        let entries = SSHConfig.entries("""
        Host alpha beta
          User shared
          Port 2022
        """)
        #expect(entries.map(\.alias) == ["alpha", "beta"])
        #expect(entries.allSatisfy { $0.user == "shared" && $0.port == 2022 })
    }

    @Test func firstValueWinsAndRepeatedAliasMerges() {
        let entries = SSHConfig.entries("""
        Host box
          User first
        Host box
          User second
          HostName box.lan
        """)
        #expect(entries.count == 1)
        #expect(entries.first?.user == "first")
        #expect(entries.first?.hostName == "box.lan")
    }

    @Test func matchBlocksAreNotAttributedToTheLastHost() {
        let entries = SSHConfig.entries("""
        Host a
          HostName a.example.com
        Match host b
          User matched
        """)
        #expect(entries.first?.user == nil)
    }

    @Test func keywordsAreCaseInsensitiveAndEqualsSignsWork() {
        let entries = SSHConfig.entries("""
        # a comment
        HOST=lab
        hostname = lab.local
        """)
        #expect(entries == [SSHConfigEntry(alias: "lab", hostName: "lab.local")])
    }

    @Test func importedHostUsesSystemSSHAndDefaults() {
        let host = Host.imported(SSHConfigEntry(alias: "lab"), localUser: "demo")
        #expect(host.name == "lab")
        #expect(host.target == SSHTarget(host: "lab", port: 22, username: "demo"))
        #expect(host.keyID == nil)
        #expect(host.systemSSH == true)
    }

    @Test func summaryShowsWhatTheEntrySets() {
        let entry = SSHConfigEntry(alias: "web", hostName: "web.example.com", user: "deploy", port: 2222,
                                   identityFile: "~/.ssh/k")
        #expect(SSHConfig.summary(entry) == "deploy@web.example.com:2222 · ~/.ssh/k")
    }
}

struct SetupCheckTests {
    @Test func pythonVersionFromTheMachine() {
        #expect(SetupCheck.parsePython("Python 3.12.4\n") == "3.12.4")
        #expect(SetupCheck.parsePython("Python 3.9\n") == "3.9")
    }

    @Test func pythonMissingOrTooOld() {
        #expect(SetupCheck.parsePython("sh: python3: command not found\n") == nil)
        #expect(SetupCheck.parsePython("Python 2.7.18\n") == nil)
        #expect(SetupCheck.parsePython("") == nil)
    }

    @Test func pythonCommandsPerPlatform() {
        #expect(SetupCheck.pythonCommand(windows: false) == "python3 --version 2>&1")
        #expect(SetupCheck.pythonCommand(windows: true).contains(#"%LOCALAPPDATA%\Programs\Python\Python313"#))
    }

    @Test func agentFoundWithVersion() {
        let found = SetupCheck.parseAgent("found\n2.0.1 (Claude Code)\n")
        #expect(found.installed)
        #expect(found.version == "2.0.1 (Claude Code)")
    }

    @Test func agentFoundWithoutVersionLine() {
        let found = SetupCheck.parseAgent("found\n")
        #expect(found.installed)
        #expect(found.version == nil)
    }

    @Test func agentNotFound() {
        let found = SetupCheck.parseAgent("")
        #expect(found.installed == false)
        #expect(found.version == nil)
    }

    @Test func agentCommandTriesEveryName() {
        let command = SetupCheck.agentCommand(.antigravity, windows: false)
        #expect(command.contains("for c in agy antigravity;"))
        let windows = SetupCheck.agentCommand(.antigravity, windows: true)
        #expect(windows.contains("where agy") && windows.contains("where antigravity"))
    }

    @Test func statusLineSetOrMissing() {
        #expect(SetupCheck.parseStatusLine("set\n"))
        #expect(SetupCheck.parseStatusLine("missing\n") == false)
        #expect(SetupCheck.parseStatusLine("") == false)
    }

    @Test func helperStatusFromTheInstaller() {
        let status = SetupCheck.parseHelper("noise\n{\"installed\": true, \"version\": 3}\n")
        #expect(status?.installed == true)
        #expect(status?.version == 3)
    }

    @Test func helperStatusNotInstalled() {
        let status = SetupCheck.parseHelper("{\"installed\": false}\n")
        #expect(status?.installed == false)
        #expect(status?.version == nil)
    }

    @Test func helperGarbageIsNoAnswer() {
        #expect(SetupCheck.parseHelper("python3: not found") == nil)
        #expect(SetupCheck.parseHelper("") == nil)
    }

    @Test func installCommandsOnlyWhereKnown() {
        #expect(AgentCLI.codex.installCommand(windows: false) == "npm install -g @openai/codex")
        #expect(AgentCLI.antigravity.installCommand(windows: false) == nil)
    }
}

struct ChannelClosedTests {
    @Test func closedChannelErrorsEndTheOutput() {
        #expect(HostSession.isChannelClosed(NIOCore.ChannelError.alreadyClosed))
        #expect(HostSession.isChannelClosed(NIOCore.ChannelError.inputClosed))
        #expect(HostSession.isChannelClosed(NIOCore.ChannelError.eof))
        #expect(!HostSession.isChannelClosed(NIOCore.ChannelError.connectPending))
        #expect(!HostSession.isChannelClosed(CommandTimeout()))
    }
}

struct SameMachineTests {
    @Test func laterEntryWithTheSameCoreIsHiddenLocalPreferred() {
        let local = Host.makeLocal()
        var ssh = Host.makeLocal(); ssh.id = UUID(); ssh.name = "192.0.2.10"; ssh.local = false
        var other = Host.makeLocal(); other.id = UUID(); other.name = "pop"; other.local = false
        // The SSH entry is first in the list, but the local connection wins.
        let hidden = SameMachine.duplicates([(ssh, "mac"), (other, "lab-box"), (local, "mac")])
        #expect(hidden.keys.sorted { $0.uuidString < $1.uuidString } == [ssh.id])
        #expect(hidden[ssh.id]?.id == local.id)
        #expect(SameMachine.duplicates([(ssh, nil), (local, nil)]).isEmpty)
    }
}
