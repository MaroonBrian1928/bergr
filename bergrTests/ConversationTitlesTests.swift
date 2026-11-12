import Foundation
import Testing
@testable import bergr

/// Counts writes and the most that run at once. Each write takes `delay`, so overlap shows.
actor FakeTitleWriter: OnDeviceTextWriting {
    private(set) var prompts: [String] = []
    private(set) var active = 0
    private(set) var peak = 0
    private var reply: String?
    private let delay: Duration

    init(reply: String? = "Fix flaky login test", delay: Duration = .milliseconds(30)) {
        self.reply = reply
        self.delay = delay
    }

    func setReply(_ text: String?) { reply = text }

    func write(instructions: String, prompt: String, timeout: Duration) async -> String? {
        prompts.append(prompt)
        active += 1
        peak = max(peak, active)
        try? await Task.sleep(for: delay)
        active -= 1
        return reply
    }
}

@MainActor
struct ConversationTitlesTests {
    /// A fresh UserDefaults suite, removed when the test ends.
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "ConversationTitlesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }

    @Test func cacheHitAvoidsASecondWrite() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter()
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            await titles.resolve(id: "a", title: "Please fix the login redirect", snippet: "")
            await titles.resolve(id: "a", title: "Please fix the login redirect", snippet: "")
            #expect(await writer.prompts.count == 1)
            #expect(titles.titles["a"] == "Fix flaky login test")

            // A new instance (a relaunch) reads the saved title and writes nothing.
            let later = FakeTitleWriter()
            let relaunched = ConversationTitles(writer: later, defaults: defaults)
            #expect(relaunched.titles["a"] == "Fix flaky login test")
            await relaunched.resolve(id: "a", title: "Please fix the login redirect", snippet: "")
            #expect(await later.prompts.isEmpty)
        }
    }

    @Test func writesAtMostThreeAtOnce() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter()
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<10 {
                    group.addTask { @MainActor in await titles.resolve(id: "c\(i)", title: "Message \(i)", snippet: "") }
                }
            }
            #expect(await writer.prompts.count == 10)
            #expect(await writer.peak == ConversationTitles.maxConcurrent)
            #expect(titles.titles.count == 10)
        }
    }

    @Test func nilReplyKeepsTheFallback() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter(reply: nil)
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            await titles.resolve(id: "n", title: "Some first message", snippet: "")
            #expect(titles.titles["n"] == nil)
            // Not asked again this session, so scrolling doesn't re-run the model.
            await titles.resolve(id: "n", title: "Some first message", snippet: "")
            #expect(await writer.prompts.count == 1)
        }
    }

    @Test func emptyTitleIsNotWritten() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter()
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            await titles.resolve(id: "e", title: "   ", snippet: "some excerpt")
            #expect(await writer.prompts.isEmpty)
            #expect(titles.titles["e"] == nil)
        }
    }

    @Test func cacheIsTrimmedAt500() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter(delay: .milliseconds(0))
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            for i in 0...ConversationTitles.limit {
                await titles.resolve(id: "t\(i)", title: "Message \(i)", snippet: "")
            }
            #expect(titles.titles.count == ConversationTitles.limit)
            #expect(titles.titles["t0"] == nil)
            #expect(titles.titles["t\(ConversationTitles.limit)"] != nil)
            let saved = defaults.data(forKey: ConversationTitles.storageKey)
            let count = saved.flatMap { try? JSONDecoder().decode([[String: String]].self, from: $0) }?.count
            #expect(count == ConversationTitles.limit)
        }
    }

    @Test func alreadyCancelledWithFreeSlotsWritesNothing() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter()
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            let task = Task { @MainActor in await titles.resolve(id: "cancelled", title: "Do not write", snippet: "") }
            task.cancel()
            await task.value
            #expect(await writer.prompts.isEmpty)
            #expect(titles.titles.isEmpty)
            // Cancellation must not mark the conversation as failed or consume a slot.
            await titles.resolve(id: "cancelled", title: "Try again", snippet: "")
            #expect(await writer.prompts.count == 1)
            #expect(titles.titles["cancelled"] != nil)
        }
    }

    @Test func cancelledWhileQueuedWritesNothing() async {
        await withDefaults { defaults in
            let writer = FakeTitleWriter()
            let titles = ConversationTitles(writer: writer, defaults: defaults)
            let busy = (0..<3).map { i in
                Task { @MainActor in await titles.resolve(id: "b\(i)", title: "Busy \(i)", snippet: "") }
            }
            try? await Task.sleep(for: .milliseconds(10))
            let queued = Task { @MainActor in await titles.resolve(id: "q", title: "Queued message", snippet: "") }
            queued.cancel()
            await queued.value
            for task in busy { await task.value }
            #expect(await writer.prompts.allSatisfy { !$0.contains("Queued message") })
            #expect(titles.titles["q"] == nil)
        }
    }
}
