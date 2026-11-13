import Foundation
import SwiftUI
import Testing
@testable import bergr

struct FilePathDetectorTests {
    private func refs(_ text: String) -> [FileRef] { FilePathDetector.matches(in: text).map(\.ref) }

    @Test func detectsPaths() {
        #expect(FilePathDetector.ref("src/foo.swift") == FileRef(path: "src/foo.swift"))
        #expect(FilePathDetector.ref("./x") == FileRef(path: "./x"))
        #expect(FilePathDetector.ref("../a/b") == FileRef(path: "../a/b"))
        #expect(FilePathDetector.ref("/etc/hosts") == FileRef(path: "/etc/hosts"))
        #expect(FilePathDetector.ref("~/notes.md") == FileRef(path: "~/notes.md"))
        #expect(FilePathDetector.ref("README.md") == FileRef(path: "README.md"))
        #expect(FilePathDetector.ref("C:\\proj\\a.py") == FileRef(path: "C:\\proj\\a.py"))
    }

    @Test func detectsLineAndColumn() {
        #expect(FilePathDetector.ref("file.swift:42") == FileRef(path: "file.swift", line: 42))
        #expect(FilePathDetector.ref("file.swift:42:7") == FileRef(path: "file.swift", line: 42, col: 7))
        #expect(FilePathDetector.ref("src/a.ts#L10") == FileRef(path: "src/a.ts", line: 10))
    }

    @Test func rejectsNonPaths() {
        for s in ["https://example.com/a/b.html", "www.example.com", "1.2.3", "v1.2.3", "and/or", "hello", "/compact",
                  "e.g.", "key:value", "std::vector", "a@b.com", "3.14", "src/main", "/"] {
            #expect(FilePathDetector.ref(s) == nil, "\(s)")
        }
    }

    @Test func findsPathsInSentences() {
        #expect(refs("I updated src/foo.swift:42.") == [FileRef(path: "src/foo.swift", line: 42)])
        #expect(refs("see (a/b.py), and/or c.rs") == [FileRef(path: "a/b.py"), FileRef(path: "c.rs")])
        #expect(refs("Visit https://x.dev/a/b.md now, version 1.2.3").isEmpty)
        let m = FilePathDetector.matches(in: "edit `x/y.go` ok")
        #expect(m.count == 1 && m[0].range == 6..<12)
    }

    @Test func urlRoundTrips() throws {
        let ref = FileRef(path: "src/a b.swift", line: 3, col: 4)
        #expect(FileRef(url: try #require(ref.url)) == ref)
        #expect(FileRef(url: URL(string: "https://x.com")!) == nil)
    }

    @Test func resolvesAgainstCwd() {
        #expect(FilePathDetector.resolve("src/a.swift", cwd: "/home/me/proj") == "/home/me/proj/src/a.swift")
        #expect(FilePathDetector.resolve("./a.swift", cwd: "/home/me/proj/") == "/home/me/proj/a.swift")
        #expect(FilePathDetector.resolve("../b/a.swift", cwd: "/home/me/proj") == "/home/me/b/a.swift")
        #expect(FilePathDetector.resolve("/etc/hosts", cwd: "/home/me") == "/etc/hosts")
        #expect(FilePathDetector.resolve("~/x/../y.md", cwd: "/home/me") == "~/y.md")
        #expect(FilePathDetector.resolve("a.swift", cwd: "C:\\proj", windows: true) == "C:\\proj\\a.swift")
        #expect(FilePathDetector.resolve("src/a.swift", cwd: "C:\\proj\\", windows: true) == "C:\\proj\\src\\a.swift")
        #expect(FilePathDetector.resolve("D:\\x.txt", cwd: "C:\\proj", windows: true) == "D:\\x.txt")
    }

    @Test func markdownLinksPaths() {
        let inline = MarkdownInline("Changed `src/a.swift:9` and lib/b.py, see [docs](https://x.dev/a.md) and `foo()`.")
        let links = inline.styled(.of(.light)).runs.compactMap(\.link)
        let files = links.compactMap(FileRef.init(url:))
        #expect(files == [FileRef(path: "src/a.swift", line: 9), FileRef(path: "lib/b.py")])
        #expect(links.contains(URL(string: "https://x.dev/a.md")!))
    }
}

struct FileLoaderTests {
    private actor Calls {
        var commands: [String] = []
        func add(_ c: String) { commands.append(c) }
    }

    private func loader(windows: Bool = false, _ reply: String) -> (FileLoader, Calls) {
        let calls = Calls()
        return (FileLoader(windows: windows) { command in await calls.add(command); return reply }, calls)
    }

    @Test func okFile() async {
        let (l, calls) = loader("BERGR:ok\na\nb\r\n\nc\n")
        let r = await l.load(FileRef(path: "x.txt"), cwd: "/p")
        #expect(r == .text(lines: ["a", "b", "", "c"], truncated: false))
        let cmd = await calls.commands[0]
        #expect(cmd.contains("'/p/x.txt'") && cmd.hasPrefix("sh -c "))
    }

    @Test func notFound() async {
        let (l, _) = loader("BERGR:notfound\n")
        #expect(await l.load(FileRef(path: "x.txt"), cwd: "/p") == .notFound)
    }

    @Test func binary() async {
        let (l, _) = loader("BERGR:binary\n")
        #expect(await l.load(FileRef(path: "x.png"), cwd: "/p") == .binary)
        #expect(FileLoader.parseWindows("MZ\u{0}\u{0}") == .binary)
    }

    @Test func tooManyLines() async {
        let body = (1...5000).map(String.init).joined(separator: "\n")
        let (l, _) = loader("BERGR:ok\n" + body)
        guard case .text(let lines, let truncated) = await l.load(FileRef(path: "x.txt"), cwd: "/p") else {
            Issue.record("not text"); return
        }
        #expect(lines.count == FileLoader.lineCap && truncated && lines.last == "4000")
    }

    @Test func tooManyBytes() async {
        let body = String(repeating: "abcdefghi\n", count: 110_000)
        let (l, _) = loader("BERGR:ok\n" + body)
        guard case .text(let lines, let truncated) = await l.load(FileRef(path: "x.txt"), cwd: "/p") else {
            Issue.record("not text"); return
        }
        #expect(truncated && lines.count == FileLoader.lineCap)
    }

    @Test func runnerError() async {
        let l = FileLoader { _ in throw CommandTimeout() }
        #expect(await l.load(FileRef(path: "a.txt"), cwd: "/p") == .failed(CommandTimeout().localizedDescription))
    }

    @Test func windowsUsesType() async {
        let (l, calls) = loader(windows: true, "one\r\ntwo\r\n")
        let r = await l.load(FileRef(path: "src/a.txt"), cwd: "C:\\proj")
        #expect(r == .text(lines: ["one", "two"], truncated: false))
        #expect(await calls.commands[0] == "type \"C:\\proj\\src\\a.txt\"")
    }
}
