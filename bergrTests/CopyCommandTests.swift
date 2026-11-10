import Testing
@testable import bergr

struct CopyCommandTests {
    @Test func findsBlocksInlineAndBang() {
        let text = "Run `git -C ~/src/bergr push origin main` then:\n```bash\njust phone\njust test\n```\nSee `main`."
        #expect(Commands.in(text) == ["just phone\njust test", "git -C ~/src/bergr push origin main"])
        #expect(Commands.in("! ls -a") == ["ls -a"])
        // A command written for shell mode, in a code block: without the `!`.
        #expect(Commands.in("To push:\n```\n! git -C ~/src/bergr push origin main\n```")
                == ["git -C ~/src/bergr push origin main"])
        #expect(Commands.in("No commands, just `name`.").isEmpty)
    }

    @Test func commandsAToolRunRan() {
        let steps: [(name: String, summary: String)] = [
            ("Bash", "Check the deploy log\ntail -50 /var/log/deploy.log"), ("Read", "deploy/servers.toml"),
            ("exec_command", "npm test"), ("Bash", "Check the deploy log\ntail -50 /var/log/deploy.log")]
        #expect(Commands.ran(steps) == ["tail -50 /var/log/deploy.log", "npm test"])
        #expect(Commands.runnable("npm test"))
        #expect(!Commands.runnable("a very long command that was cut…"))
        #expect(!Commands.runnable("line one\nline two"))
    }
}
