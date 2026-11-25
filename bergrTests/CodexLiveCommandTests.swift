import Testing
@testable import bergr

struct CodexLiveCommandTests {
    @Test func showsTheCurrentCommandAndOutput() {
        let lines = [
            "• Ran sed -n '1,3p' README.md",
            "• Running ~/src/bergr/scripts/testflight.zsh",
            "  └ Uploading Bergr 0.3.29 (1) to TestFlight.",
            "    Signing by hand with the Bergr AppStore profiles.",
            "",
            "• Working (20s • esc to interrupt)",
            "› Ask Codex to do anything",
        ]
        #expect(CodexLiveCommand.read(lines) == CodexLiveCommand(
            command: "~/src/bergr/scripts/testflight.zsh",
            output: "Uploading Bergr 0.3.29 (1) to TestFlight.\nSigning by hand with the Bergr AppStore profiles."
        ))
        #expect(CodexLiveCommand.read(Array(lines.prefix(4))) == nil)
        #expect(CodexLiveCommand.read(lines + ["• Ran ~/src/bergr/scripts/testflight.zsh"]) == nil)
    }
    @Test func readsWrappedQueuedFollowUpsAndStopsAtTheEditingHint() {
        let queued = [
            "• Queued follow-up inputs",
            "  ↳ /tmp/bergr-images/a6b7484f-fbef-49bb-b400-",
            "    25f18c00d13f.jpg I still want something like this",
            "    in convo for codex",
            "  ↳ Another follow-up",
            "    ⇧← edit last queued message",
            "› current draft",
        ]
        #expect(CodexQueuedInputs.read(queued) == [
            "/tmp/bergr-images/a6b7484f-fbef-49bb-b400-25f18c00d13f.jpg I still want something like this in convo for codex",
            "Another follow-up",
        ])
        #expect(CodexQueuedInputs.read(Array(queued.dropFirst())) == [])
        let working = "• Working (20s • esc to interrupt)"
        let running = ["• Running sleep 20", "  └ Waiting"]
        #expect(CodexLiveCommand.read(running + queued + [working])?.output == "Waiting")
        #expect(CodexLiveCommand.read(running + [working] + queued)?.output == "Waiting")
    }
}
