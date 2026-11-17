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
    #expect(list.terminals.count == 6)
    #expect(list.terminals.first { $0.address == "t3" }?.status?.state == "blocked")
    #expect(list.terminals.first { $0.address == "t2" }?.parent == "t1")

    let layout = try #require(try await client.herdrAppLayout())
    let sections = TerminalGrouping.bySpace(list.terminals, layout: layout)
    #expect(sections.map(\.title) == ["website", "shop-api"])
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

/// The permission prompt is a numbered menu: Return on "Yes" runs the migration, and the agent
/// then stops at a second, dangerous prompt. It goes on when nobody is attached.
@Test(.timeLimit(.minutes(1))) func demoApprovalUnblocksTheAgent() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let events = try await client.subscribeEvents()
    var snapshot = events.snapshot
    let attached = try await client.attach(terminal: "t3", cols: 44, rows: 20)
    let screen = Screen(attached.output)
    let asked = try await screen.wait(for: "3. No")
    #expect(asked.contains(DemoBeat.migrationCommand))
    #expect(asked.contains(DemoBeat.migrationQuestion))
    #expect(asked.contains("1. Yes"))

    try await attached.send(Data("\r".utf8))
    await attached.detach()
    var seen: [String] = []
    for try await message in events.messages {
        snapshot.apply(message)
        guard let status = snapshot["t3"]?.status else { continue }
        if seen.last != status.state { seen.append(status.state) }
        if status.state == "blocked", status.title == DemoBeat.dropQuestion { break }
    }
    #expect(seen.suffix(2) == ["working", "blocked"])

    // Down to "No", Return: the turn ends with the table kept.
    let again = try await client.attach(terminal: "t3", cols: 44, rows: 20)
    #expect(try await Screen(again.output).wait(for: "2. No").contains(DemoBeat.dropCommand))
    try await again.send(Data("\u{1b}[B\r".utf8))
    for try await message in events.messages {
        snapshot.apply(message)
        if snapshot["t3"]?.status?.state == "done" { break }
    }
    #expect(snapshot["t3"]?.status?.msg == DemoBeat.totalsDoneKept)
}

/// "No" to the migration stops the agent.
@Test(.timeLimit(.minutes(1))) func demoApprovalCanBeRefused() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }

    let events = try await client.subscribeEvents()
    var snapshot = events.snapshot
    let attached = try await client.attach(terminal: "t3", cols: 44, rows: 20)
    _ = try await Screen(attached.output).wait(for: "3. No")
    try await attached.send(Data("3".utf8))
    for try await message in events.messages {
        snapshot.apply(message)
        if snapshot["t3"]?.status?.state == "idle" { break }
    }
    #expect(snapshot["t3"]?.status?.msg == DemoBeat.migrationSkipped)
}

/// Each demo machine has its own terminals, and addresses never repeat across them (the app's UI
/// tests find a row by its address alone).
@Test(.timeLimit(.minutes(1))) func demoMachinesShowDifferentAgents() async throws {
    var addresses: [String] = []
    for machine in DemoMachine.allCases {
        let client = try await HerdrClient.connectDemo(machine: machine)
        defer { Task { await client.close() } }
        #expect(await client.hello?.core.name == machine.name)
        let list = try await client.listTerminals()
        addresses += list.terminals.map(\.address)
        let layout = try #require(try await client.herdrAppLayout())
        let placed = TerminalGrouping.bySpace(list.terminals, layout: layout).flatMap(\.rows).count
        #expect(placed == list.terminals.count)
    }
    #expect(Set(addresses).count == addresses.count)
    #expect(DemoMachine(target: "demo") == .studio)
    #expect(DemoMachine(target: "demo-buildbox") == .buildbox)
    #expect(DemoMachine(target: "example.org") == nil)
}

/// One agent is at work when the demo starts, and the timeline finishes it: the rest are still.
@Test func demoHasOneWorkingAgentThatFinishes() {
    let all = DemoMachine.allCases.flatMap { DemoScript.terminals($0) }
    #expect(all.filter { $0.status?.state == "working" }.map(\.address) == [DemoBeat.upgradeAgent])
    #expect(Set(all.compactMap { $0.status?.state }) == ["working", "blocked", "done", "idle"])
    let steps = DemoMachine.allCases.flatMap { DemoScript.timeline($0) }
    #expect(steps.allSatisfy { $0.address == DemoBeat.upgradeAgent })
    #expect(steps.last?.status?.state == "done")
}

/// Screens fit a folded phone: no line of a demo screen is wider than 44 columns.
@Test func demoScreensFitFortyFourColumns() {
    func plain(_ text: String) -> [String] {
        text.replacing(/\u{1b}\[[0-9;]*[A-Za-z]/, with: "").components(separatedBy: "\r\n")
    }
    for machine in DemoMachine.allCases {
        for (address, role) in DemoScript.roles(machine) {
            guard case .agent = role else { continue }
            for line in plain(role.paint) { #expect(line.count <= 44, "\(address): \(line)") }
        }
    }
    for prompt in [DemoScript.migrationPrompt, DemoScript.dropPrompt] {
        for line in plain(prompt.paint(selected: 0)) { #expect(line.count <= 44, "\(line)") }
    }
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

/// The demo's agents run under the names of the agents Bergr knows (the app picks a row's mark and
/// its chat from the program), so the list and the chats read like real sessions. The terminal
/// screens themselves stay generic: no product name is drawn in them.
@Test func demoAgentsRunKnownProgramsAndScreensStayGeneric() {
    let programs = DemoMachine.allCases.flatMap { DemoScript.terminals($0) }
        .filter { $0.status != nil }.compactMap { $0.foreground?.name }
    #expect(programs.sorted() == ["agy", "claude", "claude", "codex", "codex"])
    let brands = ["claude", "codex", "antigravity", "gemini", "gpt"]
    for machine in DemoMachine.allCases {
        for (address, role) in DemoScript.roles(machine) {
            #expect(!brands.contains { role.paint.lowercased().contains($0) }, "\(address)")
        }
    }
}
