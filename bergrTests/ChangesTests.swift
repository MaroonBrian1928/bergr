import Testing
@testable import bergr

struct ChangesTests {
    @Test func statusBranchAndEntries() {
        let s = GitParsing.status("""
        ## main...origin/main [ahead 2, behind 1]
         M src/a.swift
        M  b.txt
        R  old.txt -> new.txt
        ?? scratch.md
        ?? "dir/x y"
        """)
        #expect(s.branch == "main" && s.upstream == "origin/main" && s.ahead == 2 && s.behind == 1)
        #expect(s.entries.count == 5 && s.untrackedCount == 2)
        #expect(s.entries[0].path == "src/a.swift" && s.entries[0].y == "M")
        #expect(s.entries[1].isStaged)
        #expect(s.entries[2].from == "old.txt" && s.entries[2].path == "new.txt" && s.entries[2].label == "renamed")
        #expect(s.entries[4].path == "dir/x y")
    }

    @Test func statusBranchVariants() {
        #expect(GitParsing.status("## feature").branch == "feature")
        let n = GitParsing.status("## No commits yet on main\n?? a")
        #expect(n.noCommits && n.branch == "main")
        #expect(GitParsing.status("## HEAD (no branch)").branch == "HEAD (detached)")
        #expect(GitParsing.status("## m...o/m [behind 3]").behind == 3)
    }

    @Test func statParses() {
        let s = GitParsing.stat("""
         a/b.swift | 12 ++++++----
         img.png   | Bin 0 -> 120 bytes
         2 files changed, 6 insertions(+), 4 deletions(-)
        """)
        #expect(s.files.count == 2 && s.files[0].path == "a/b.swift" && s.files[0].plus == 6 && s.files[0].minus == 4)
        #expect(s.files[1].binary)
        #expect(s.insertions == 6 && s.deletions == 4)
    }

    @Test func diffHunks() {
        let d = GitParsing.diff("diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@ func x\n keep\n-old\n+new\n@@ -10 +10 @@\n-a\n+b\n")
        #expect(d.meta.count == 4)
        #expect(d.hunks.count == 2)
        #expect(d.hunks[0].lines.map(\.kind) == [.context, .del, .add])
        #expect(d.hunks[1].lines.count == 2)
        #expect(GitParsing.diff("Binary files a and b differ").isBinary)
    }

    @Test func detectsTestCommands() {
        for c in ["pytest -x", "npm test", "cargo test --lib", "go test ./...", "just test", "xcodebuild test -scheme a", "npx jest"] {
            #expect(TestRun.isTestCommand(c), "\(c)")
        }
        #expect(!TestRun.isTestCommand("xcodebuild build -scheme a"))
        #expect(!TestRun.isTestCommand("ls -la"))
    }

    @Test func picksLastTestRun() {
        let items: [ChatFeed.Item] = [
            .init(id: "1", kind: .tool(name: "Bash", summary: "Run tests\npytest")),
            .init(id: "2", kind: .tool(name: "Bash", summary: "Run again\nnpm test")),
            .init(id: "3", kind: .tool(name: "Bash", summary: "ls")),
        ]
        let run = TestRun.last(in: items, output: ["2": "Tests: 3 passed, 3 total"])
        #expect(run?.command == "npm test" && run?.verdict == .passed)
        #expect(TestRun.last(in: [], output: [:]) == nil)
    }

    @Test func verdicts() {
        #expect(TestRun.verdict("test result: ok. 5 passed; 0 failed") == .passed)
        #expect(TestRun.verdict("1 failed, 4 passed") == .failed)
        #expect(TestRun.verdict("** TEST FAILED **") == .failed)
        #expect(TestRun.verdict("** TEST SUCCEEDED **") == .passed)
        #expect(TestRun.verdict("") == .unknown)
        #expect(TestRun.verdict("hello") == .unknown)
    }
}
