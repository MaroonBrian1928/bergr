import Foundation
import Testing
@testable import HerdrKit

/// Collects a terminal's output in the background, so tests can wait for text.
private actor Screen {
    private(set) var text = ""
    private var reader: Task<Void, Never>?

    init(_ output: AsyncThrowingStream<Data, Error>) {
        reader = nil
        Task { await self.start(output) }
    }

    private func start(_ output: AsyncThrowingStream<Data, Error>) {
        reader = Task {
            do {
                for try await chunk in output { self.append(chunk) }
            } catch {}
        }
    }

    private func append(_ chunk: Data) { text += String(decoding: chunk, as: UTF8.self) }

    /// Waits until the output contains `needle`; returns everything seen.
    func wait(for needle: String) async throws -> String {
        while !text.contains(needle) { try await Task.sleep(for: .milliseconds(20)) }
        return text
    }
}

@Test(.timeLimit(.minutes(1))) func demoCoreListsSpacesAndTerminals() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    #expect(await client.hello?.version == "demo")
    let list = try await client.listTerminals()
    #expect(list.terminals.count == 7)
    #expect(list.terminals.first { $0.address == "t3" }?.status?.state == "blocked")
    #expect(list.terminals.first { $0.address == "t2" }?.parent == "t1")

    let layout = try #require(try await client.herdrAppLayout())
    let sections = TerminalGrouping.bySpace(list.terminals, layout: layout)
    #expect(sections.map(\.title) == ["website", "shop-api", "infra"])
    // The tests run under the agent that started them.
    #expect(sections[0].rows.map(\.terminal.address) == ["t1", "t2", "t4"])
    #expect(sections[0].rows[1].depth == 1)
}

@Test(.timeLimit(.minutes(1))) func demoShellAnswersCommands() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let attached = try await client.attach(terminal: "t5", cols: 44, rows: 20)
    let screen = Screen(attached.output)
    #expect(try await screen.wait(for: "Update dependencies").contains("git log"))

    try await attached.send(Data("pwd\r".utf8))
    let after = try await screen.wait(for: "/Users/demo/projects/shop-api\r\n")
    #expect(after.contains("pwd\r\n"))
}

@Test(.timeLimit(.minutes(1))) func demoApprovalUnblocksTheAgent() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let events = try await client.subscribeEvents()
    var snapshot = events.snapshot
    let attached = try await client.attach(terminal: "t3", cols: 44, rows: 20)
    let screen = Screen(attached.output)
    #expect(try await screen.wait(for: "Allow?").contains("npm run migrate"))

    try await attached.send(Data("y".utf8))
    for try await message in events.messages {
        snapshot.apply(message)
        if snapshot["t3"]?.status?.state == "working" { break }
    }
    #expect(snapshot["t3"]?.status?.title == "Running the migration")
}

@Test(.timeLimit(.minutes(1))) func demoRunsAndKillsTerminals() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let events = try await client.subscribeEvents()
    var snapshot = events.snapshot
    let terminal = try await client.run(RunRequest(cwd: DemoScript.website, name: "scratch"))
    #expect(terminal.address == "t8")
    #expect(terminal.isLive)

    try await client.kill("t8")
    for try await message in events.messages {
        snapshot.apply(message)
        if snapshot["t8"]?.isLive == false { break }
    }
    #expect(snapshot["t8"]?.reason == "killed")

    try await client.remove("t8")
    await #expect(throws: HerdrError.self) { try await client.attach(terminal: "t8", cols: 40, rows: 10) }
}

/// Like herdr-core's `observe`: watching leaves the terminal's size alone and ignores typing.
@Test(.timeLimit(.minutes(1))) func demoObserverWatchesWithoutResizingOrTyping() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let before = try #require(try await client.listTerminals().terminals.first { $0.address == "t5" })
    let observer = try await client.attach(terminal: "t5", cols: before.cols + 7, rows: before.rows + 3, observe: true)
    let screen = Screen(observer.output)
    _ = try await screen.wait(for: "Update dependencies")
    try await observer.resize(cols: before.cols + 9, rows: before.rows + 5)
    try await observer.send(Data("pwd\r".utf8))
    try await Task.sleep(for: .milliseconds(300))

    let after = try #require(try await client.listTerminals().terminals.first { $0.address == "t5" })
    #expect(after.cols == before.cols && after.rows == before.rows)
    #expect(!(await screen.text.contains("/Users/demo/projects/shop-api\r\n")))
}
