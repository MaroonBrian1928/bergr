import Foundation
import Testing
@testable import bergr

struct WorktreesTests {
    @Test func sanitizesBranchNames() {
        #expect(Worktrees.sanitizeBranch("  my feature!  ") == "my-feature")
        #expect(Worktrees.sanitizeBranch("bergr/claude--x//y") == "bergr/claude-x/y")
        #expect(Worktrees.sanitizeBranch("a..b") == "a.b")
        #expect(Worktrees.sanitizeBranch("/-.x.lock") == "x")
        #expect(Worktrees.sanitizeBranch("héllo wörld") == "h-llo-w-rld")
        #expect(Worktrees.sanitizeBranch("   ") == "")
    }

    @Test func defaultBranchAndSlug() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 5))!
        #expect(Worktrees.defaultBranch(agent: .claude, date: date, calendar: cal) == "bergr/claude-1105")
        #expect(Worktrees.defaultBranch(agent: .antigravity, date: date, calendar: cal) == "bergr/agy-1105")
        #expect(Worktrees.slug("bergr/claude-1105") == "bergr-claude-1105")
    }

    @Test func pathChoice() {
        #expect(Worktrees.basePath(folder: "/home/me/src/app", branch: "bergr/x", windows: false) == "/home/me/src/app-bergr-x")
        #expect(Worktrees.basePath(folder: "/home/me/src/app/", branch: "x", windows: false) == "/home/me/src/app-x")
        #expect(Worktrees.basePath(folder: "C:\\src\\app", branch: "bergr/x", windows: true) == "C:\\src\\app-bergr-x")
        let base = "/p/app-x"
        #expect(Worktrees.choosePath(base: base, existing: []) == base)
        #expect(Worktrees.choosePath(base: base, existing: [base]) == "/p/app-x-2")
        #expect(Worktrees.choosePath(base: base, existing: [base, "/p/app-x-2", "/p/app-x-3"]) == "/p/app-x-4")
        #expect(Worktrees.candidates(base: base, count: 3) == [base, "/p/app-x-2", "/p/app-x-3"])
    }

    @Test func commandsPosix() {
        let path = "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; "
        #expect(Worktrees.addCommand(folder: "/h/my app", branch: "bergr/x", path: "/h/my app-bergr-x", windows: false)
                == path + "git -C '/h/my app' worktree add -b 'bergr/x' '/h/my app-bergr-x' </dev/null 2>&1 && echo __BERGR_OK__")
        #expect(Worktrees.removeCommand(repo: "/h/it's", path: "/h/w", windows: false)
                == path + "git -C '/h/it'\\''s' worktree remove '/h/w' </dev/null 2>&1 && echo __BERGR_OK__")
        #expect(Worktrees.branchCommand(cwd: "/h/a", windows: false)
                == path + "git -C '/h/a' rev-parse --abbrev-ref HEAD --git-dir --git-common-dir </dev/null 2>/dev/null")
        #expect(Worktrees.existsCommand(paths: ["/a", "/a-2"], windows: false)
                == "for p in '/a' '/a-2'; do [ -e \"$p\" ] && printf '%s\\n' \"$p\"; done; true")
    }

    @Test func commandsWindows() {
        #expect(Worktrees.addCommand(folder: "C:\\src\\app", branch: "bergr/x", path: "C:\\src\\app-bergr-x", windows: true)
                == #"cmd /d /s /c "git -C "C:\src\app" worktree add -b bergr/x "C:\src\app-bergr-x" 2>&1 && echo __BERGR_OK__""#)
        #expect(Worktrees.removeCommand(repo: "C:\\src\\app", path: "C:\\src\\w", windows: true)
                == #"cmd /d /s /c "git -C "C:\src\app" worktree remove "C:\src\w" 2>&1 && echo __BERGR_OK__""#)
        #expect(Worktrees.branchCommand(cwd: "C:\\src\\app", windows: true)
                == #"cmd /d /s /c "git -C "C:\src\app" rev-parse --abbrev-ref HEAD --git-dir --git-common-dir 2>nul""#)
        #expect(Worktrees.existsCommand(paths: ["C:\\a", "C:\\a-2"], windows: true)
                == #"cmd /d /s /c "if exist "C:\a" echo C:\a & if exist "C:\a-2" echo C:\a-2""#)
    }

    @Test func subfolderOfRepo() {
        // POSIX: the worktree goes beside the repo root, never inside it.
        #expect(Worktrees.parseToplevel("/h/src/app\n", windows: false) == "/h/src/app")
        #expect(Worktrees.parseToplevel("fatal: not a git repository\n", windows: false) == nil)
        #expect(Worktrees.relativePath(folder: "/h/src/app/pkg/core", root: "/h/src/app") == "pkg/core")
        #expect(Worktrees.relativePath(folder: "/h/src/app", root: "/h/src/app") == "")
        #expect(Worktrees.relativePath(folder: "/h/src/app2", root: "/h/src/app") == nil)
        let base = Worktrees.basePath(folder: "/h/src/app", branch: "bergr/x", windows: false)
        #expect(base == "/h/src/app-bergr-x")
        let path = Worktrees.choosePath(base: base, existing: [base])
        #expect(path == "/h/src/app-bergr-x-2")
        #expect(Worktrees.startFolder(worktree: path, relative: "pkg/core", windows: false) == "/h/src/app-bergr-x-2/pkg/core")
        #expect(Worktrees.startFolder(worktree: path, relative: "", windows: false) == path)
        #expect(Worktrees.toplevelCommand(cwd: "/h/a", windows: false)
                == "export PATH=\"$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; git -C '/h/a' rev-parse --show-toplevel </dev/null 2>/dev/null")

        // Windows: git prints forward slashes; the result uses backslashes.
        let root = Worktrees.parseToplevel("C:/src/app\n", windows: true)
        #expect(root == "C:\\src\\app")
        #expect(Worktrees.relativePath(folder: "C:\\src\\app\\pkg\\core", root: root!) == "pkg/core")
        let wbase = Worktrees.basePath(folder: root!, branch: "bergr/x", windows: true)
        #expect(wbase == "C:\\src\\app-bergr-x")
        let wpath = Worktrees.choosePath(base: wbase, existing: [wbase])
        #expect(Worktrees.startFolder(worktree: wpath, relative: "pkg/core", windows: true) == "C:\\src\\app-bergr-x-2\\pkg\\core")
        #expect(Worktrees.toplevelCommand(cwd: "C:\\src\\app\\pkg", windows: true)
                == #"cmd /d /s /c "git -C "C:\src\app\pkg" rev-parse --show-toplevel 2>nul""#)
    }

    @Test func resultMarker() {
        #expect(Worktrees.succeeded("Preparing worktree\n__BERGR_OK__\n"))
        #expect(!Worktrees.succeeded("fatal: 'x' already exists"))
        #expect(Worktrees.failureText("fatal: a branch named 'x' already exists\n") == "fatal: a branch named 'x' already exists")
        #expect(Worktrees.failureText("") == "git didn't say why.")
    }

    @Test func parsesRevParse() {
        #expect(Worktrees.parseBranchInfo("main\n.git\n.git\n") == .init(branch: "main", isLinkedWorktree: false))
        #expect(Worktrees.parseBranchInfo("feat/x\n/r/.git/worktrees/w\n/r/.git\n") == .init(branch: "feat/x", isLinkedWorktree: true))
        #expect(Worktrees.parseBranchInfo("HEAD\n/r/.git\n/r/.git/\n") == .init(branch: nil, isLinkedWorktree: false))
        #expect(Worktrees.parseBranchInfo("") == nil)
        #expect(Worktrees.parseBranchInfo("fatal: not a git repository\n") == nil)
        #expect(Worktrees.rowText(.init(branch: "x", isLinkedWorktree: true)) == "x · worktree")
        #expect(Worktrees.rowText(.init(branch: nil, isLinkedWorktree: false)) == "detached")
    }

    @MainActor @Test func cacheRefreshRules() async {
        let store = BranchInfoStore()
        let host = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        var calls = 0
        let info = Worktrees.BranchInfo(branch: "main", isLinkedWorktree: false)
        func fetch() async -> Worktrees.BranchInfo? { calls += 1; return info }

        await store.refresh(host: host, cwd: "/a", now: t0, fetch: fetch)
        #expect(calls == 1)
        #expect(store.info(host: host, cwd: "/a") == info)
        await store.refresh(host: host, cwd: "/a", now: t0.addingTimeInterval(30), fetch: fetch)
        #expect(calls == 1)
        await store.refresh(host: host, cwd: "/a", force: true, now: t0.addingTimeInterval(31), fetch: fetch)
        #expect(calls == 2)
        await store.refresh(host: host, cwd: "/a", now: t0.addingTimeInterval(31 + 60), fetch: fetch)
        #expect(calls == 3)
        await store.refresh(host: host, cwd: "/b", now: t0, fetch: { calls += 1; return nil })
        #expect(calls == 4)
        #expect(store.info(host: host, cwd: "/b") == nil)
    }
}
