import Testing
@testable import bergr

struct RestartCommandTests {
    @Test func keepsOptionsAndResumesThisConversation() {
        #expect(RestartCommand.make(argv: ["claude", "--resume", "old-id"], conversation: "new-id")
                == "claude --resume new-id")
        #expect(RestartCommand.make(argv: ["/Users/me/.local/share/claude/versions/2.1.319", "--model", "opus", "-c"],
                                    conversation: "abc")
                == "claude --model opus --resume abc")
        #expect(RestartCommand.make(argv: ["claude", "--append-system-prompt", "be nice"], conversation: "x")
                == "claude --append-system-prompt 'be nice' --resume x")
    }
}
