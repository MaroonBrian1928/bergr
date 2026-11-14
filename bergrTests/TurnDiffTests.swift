import Foundation
import Testing
@testable import bergr

private actor Commands {
    var all: [String] = []
    func add(_ c: String) { all.append(c) }
}

@MainActor
struct TurnDiffTests {
    private func model(address: String?, hasRef: Bool, log: Commands) -> ChangesModel {
        ChangesModel(folder: "/repo", address: address, expensive: true, lastReply: nil) { command in
            await log.add(command)
            if command.contains("rev-parse --verify") {
                if hasRef { return "abc123\n" }
                throw CocoaError(.fileNoSuchFile)
            }
            if command.contains("status --porcelain") { return "## main\n M a.txt\n" }
            if command.contains("--stat") { return " a.txt | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n" }
            if command.contains("ls-files") { return "old.txt\nnew.txt\n" }
            if command.contains("cat-file -p") { return "old.txt\n" }
            return ""
        }
    }

    @Test func refNameMatchesHelper() {
        #expect(ChangesModel.turnRefName("w:1.2") == "w_1_2")
        #expect(ChangesModel.turnRefName("a-b_c9") == "a-b_c9")
        #expect(ChangesModel.turnRefName("") == "_")
    }

    @Test func lastTurnCommandsUseTheSnapshotRef() async {
        let log = Commands()
        let m = model(address: "w:1.2", hasRef: true, log: log)
        await m.load()
        #expect(m.turnSnapshot == .available)
        await m.setScope(.lastTurn)
        #expect(m.scope == .lastTurn)
        let cmds = await log.all
        #expect(cmds.contains("git -C \"/repo\" diff refs/bergr/turns/w_1_2 --stat=120 --no-color"))
        #expect(cmds.contains("git -C \"/repo\" cat-file -p refs/bergr/turns-untracked/w_1_2"))
        #expect(m.newFiles == ["new.txt"])
        #expect(m.stat.files.map(\.path) == ["a.txt"])
        await m.loadDiff("a.txt")
        let after = await log.all
        #expect(after.contains(ChangesModel.fileDiffCommand(folder: "/repo", base: "refs/bergr/turns/w_1_2", path: "a.txt")))
        #expect(ChangesModel.fileDiffCommand(folder: "/repo", base: "refs/bergr/turns/x", path: "a b")
                == "git -C \"/repo\" diff refs/bergr/turns/x --no-color --no-ext-diff -- \"a b\"")
    }

    @Test func disabledWithoutSnapshotOrAddress() async {
        for (address, hasRef) in [("w:1.2", false), (nil, true)] as [(String?, Bool)] {
            let m = model(address: address, hasRef: hasRef, log: Commands())
            await m.load()
            #expect(m.turnSnapshot == .unavailable)
            await m.setScope(.lastTurn)
            #expect(m.scope == .all)
        }
        #expect(ChangesModel.turnUnavailableText.contains("helper v18"))
    }

    @Test func parsesFileListsAndNewFiles() {
        #expect(GitParsing.fileList("a\n\"b c\"\n\n") == ["a", "b c"])
        #expect(GitParsing.newFiles(now: ["a", "b"], before: ["a"]) == ["b"])
        #expect(GitParsing.newFiles(now: ["a", "b"], before: nil) == ["a", "b"])
    }
}
