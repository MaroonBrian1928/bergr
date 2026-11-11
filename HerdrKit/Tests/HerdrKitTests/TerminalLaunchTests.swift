import Testing
@testable import HerdrKit

@Suite struct TerminalLaunchTests {
    @Test func localAttachUsesLoginShell() throws {
        #expect(try AttachCommand.argv(remote: nil, address: "t7") == ["/bin/zsh", "-lc", "exec hc attach 't7'"])
        #expect(try AttachCommand.argv(remote: nil, address: "mac/t7.1_a") == ["/bin/zsh", "-lc", "exec hc attach 'mac/t7.1_a'"])
    }

    @Test func remoteAttachDefaultPort() throws {
        let r = AttachCommand.Remote(user: "brian", host: "pop-os.local")
        #expect(try AttachCommand.argv(remote: r, address: "t7") == [
            "ssh", "-t", "brian@pop-os.local", "PATH=\"$HOME/.local/bin:$PATH\" hc attach 't7'",
        ])
    }

    @Test func remoteAttachCustomPortAndIPv6() throws {
        let r = AttachCommand.Remote(user: "pi", host: "fe80::1", port: 2222)
        let argv = try AttachCommand.argv(remote: r, address: "box/t2")
        #expect(argv == ["ssh", "-t", "-p", "2222", "pi@fe80::1", "PATH=\"$HOME/.local/bin:$PATH\" hc attach 'box/t2'"])
    }

    @Test func hostileAddressesAreRefused() {
        for bad in ["", "t7; rm -rf ~", "$(id)", "`id`", "a b", "t7'", "t7\"", "-h", "t7\nid", "a|b", "a&b", "a>b", "é"] {
            #expect(throws: AttachCommand.Refusal.address) { try AttachCommand.argv(remote: nil, address: bad) }
            #expect(throws: AttachCommand.Refusal.address) {
                try AttachCommand.argv(remote: .init(user: "u", host: "h"), address: bad)
            }
        }
    }

    @Test func hostileUserHostPortAreRefused() {
        for bad in ["", "-oProxyCommand=x", "a b", "a;b", "a'b", "$(x)", "a\nb", "a@b"] {
            #expect(throws: AttachCommand.Refusal.user) {
                try AttachCommand.argv(remote: .init(user: bad, host: "h"), address: "t1")
            }
        }
        for bad in ["", "-oProxyCommand=x", "a b", "h;id", "h'x", "h$(x)", "h`x`", "h\nx", "u@h"] {
            #expect(throws: AttachCommand.Refusal.host) {
                try AttachCommand.argv(remote: .init(user: "u", host: bad), address: "t1")
            }
        }
        for bad in [0, -1, 65536, 99999] {
            #expect(throws: AttachCommand.Refusal.port) {
                try AttachCommand.argv(remote: .init(user: "u", host: "h", port: bad), address: "t1")
            }
        }
    }

    @Test func scriptQuotesEveryArgument() throws {
        let argv = try AttachCommand.argv(remote: .init(user: "u", host: "h", port: 2200), address: "t1")
        #expect(AttachCommand.script(argv: argv) ==
            "#!/bin/zsh -l\nunset -m 'HC_*' 'HERDR_*'\nexec 'ssh' '-t' '-p' '2200' 'u@h' 'PATH=\"$HOME/.local/bin:$PATH\" hc attach '\\''t1'\\'''\n")
        #expect(AttachCommand.quote("it's") == "'it'\\''s'")
    }

    @Test func launchPlans() {
        let app = "/Applications/X.app", s = "/tmp/a.command"
        #expect(TerminalApp.ghostty.launchPlan(appPath: app, script: s) ==
            LaunchPlan(executable: "/usr/bin/open", arguments: ["-na", app, "--args", "-e", s]))
        #expect(TerminalApp.iterm2.launchPlan(appPath: app, script: s) ==
            LaunchPlan(executable: "/usr/bin/open", arguments: ["-a", app, s]))
        #expect(TerminalApp.terminal.launchPlan(appPath: app, script: s) ==
            LaunchPlan(executable: "/usr/bin/open", arguments: ["-a", app, s]))
        #expect(TerminalApp.wezterm.launchPlan(appPath: app, script: s) ==
            LaunchPlan(executable: app + "/Contents/MacOS/wezterm", arguments: ["start", "--", s]))
        #expect(TerminalApp.kitty.launchPlan(appPath: app, script: s) ==
            LaunchPlan(executable: app + "/Contents/MacOS/kitty", arguments: ["--single-instance", "--", s]))
    }

    @Test func bundleIDs() {
        #expect(TerminalApp.allCases.map(\.bundleID) == [
            "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal",
            "com.github.wez.wezterm", "net.kovidgoyal.kitty",
        ])
    }
}
