import Testing
@testable import bergr

struct CopyCommandTests {
    @Test func findsBlocksInlineAndBang() {
        let text = "Run `git -C ~/src/bergr push origin main` then:\n```bash\njust phone\njust test\n```\nSee `main`."
        #expect(Commands.in(text) == ["just phone\njust test", "git -C ~/src/bergr push origin main"])
        #expect(Commands.in("! ls -a") == ["ls -a"])
        #expect(Commands.in("No commands, just `name`.").isEmpty)
    }
}
