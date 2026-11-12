import Foundation
import Testing
import TerminalCore
import UIKit
@testable import bergr

/// A terminal that logs what is typed. Automation runs one sequence at a time, like the real one,
/// and can be held back to leave a sequence waiting.
@MainActor final class FakeTerminal: ReplyTerminal {
    var textLines: [String] = []
    var frameLines: [String] = []
    var log: [String] = []
    var held = false
    private var tail: Task<Void, Never>?

    func automate(_ steps: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            while held { try? await Task.sleep(for: .milliseconds(1)) }
            await steps()
        }
        tail = task
        await task.value
    }

    func type(_ text: String) { log.append("type:\(text)") }
    func paste(_ text: String) { log.append("paste:\(text)") }
    func press(_ key: TerminalKey) { log.append(key == .enter ? "enter" : key == .escape ? "escape" : "key") }

    func count(_ entry: String) -> Int { log.filter { $0 == entry }.count }
}

@MainActor final class ReplyRig {
    let terminal = FakeTerminal()
    let outbox = ReplyOutbox()
    var state: String?
    var items: [ChatFeed.Item] = []
    var reconnectHeld = false
    var upload: Result<String, Error> = .success("/tmp/pic.jpg")
    var stateReads = 0

    struct Boom: Error {}

    init(confirmEnterWait: Duration = .milliseconds(15)) {
        let timing = ReplyTiming(enterDelay: .milliseconds(1), shellBangDelay: .milliseconds(1),
                                 confirmEnterWait: confirmEnterWait, confirmEnterTries: 2,
                                 firstCheck: .milliseconds(10), recheck: .milliseconds(10),
                                 imagesGiveUp: .milliseconds(30), stopWait: .milliseconds(20),
                                 poll: .milliseconds(1), stoppedSettle: .milliseconds(1))
        outbox.environment = ReplyEnvironment(
            terminal: terminal,
            agentState: { [self] in stateReads += 1; return state },
            feedItems: { [self] in items },
            upload: { [self] _ in try upload.get() },
            reconnect: { [self] in
                while reconnectHeld { try? await Task.sleep(for: .milliseconds(1)) }
            },
            timing: timing)
    }

    func send(_ text: String, images: [ChatAttachment] = [], onUploadFailure: @escaping @MainActor (Error) -> Void = { _ in }) -> ReplyDelivery {
        outbox.send(text: text, images: images, interrupting: false, onUploadFailure: onUploadFailure)!
    }

    func image() -> ChatAttachment { ChatAttachment(id: UUID(), thumbnail: UIImage(), data: Data([1, 2, 3])) }

    /// Waits for a condition (no sleeping longer than a millisecond at a time).
    func until(_ what: String = "", _ condition: () -> Bool) async {
        for _ in 0..<1500 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(condition(), "\(what)")
    }

    func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func user(_ id: String, _ text: String) -> ChatFeed.Item { .init(id: id, kind: .user(text)) }
}

@MainActor struct ReplyDeliveryTests {
    @Test func earlierIdenticalMessageDoesNotConfirm() async {
        let rig = ReplyRig()
        rig.items = [rig.user("u1", "yes")]
        let reply = rig.send("yes")
        rig.outbox.feedChanged(rig.items)
        #expect(rig.outbox.replies.count == 1)
        #expect(rig.outbox.shown(in: rig.items, search: nil).count == 1)
        rig.items.append(rig.user("u2", "yes"))
        #expect(rig.outbox.shown(in: rig.items, search: nil).isEmpty)
        rig.outbox.feedChanged(rig.items)
        #expect(rig.outbox.replies.isEmpty)
        #expect(reply.phase == .confirmed)
    }

    @Test func uploadFailureRemovesOwnBubbleOnly() async {
        let rig = ReplyRig()
        rig.state = "working"
        let first = rig.send("first")
        rig.upload = .failure(ReplyRig.Boom())
        var failures = 0
        let second = rig.send("", images: [rig.image()]) { _ in failures += 1 }
        await rig.until("failure reported") { failures == 1 }
        #expect(rig.outbox.replies.map(\.id) == [first.id])
        #expect(second.phase != .failed)
        await rig.pause(5)
        #expect(!rig.terminal.log.contains { $0.hasPrefix("paste") })
        #expect(rig.terminal.log.contains("type:first"))
    }

    @Test func retryLeavesOneMonitor() async {
        let rig = ReplyRig()
        rig.terminal.textLines = ["> hello there"]
        let reply = rig.send("hello there")
        // Retried while the first monitor still waits: only the newer one may keep watching.
        await rig.until("typed") { rig.terminal.count("enter") >= 1 }
        rig.outbox.retry(reply.id)
        await rig.until("retry typed") { rig.terminal.count("enter") >= 2 }
        rig.stateReads = 0
        await rig.pause(45)
        // One monitor looks every 10 ms at most; the sleeping old one would have doubled that.
        #expect(rig.stateReads <= 6, "\(rig.stateReads)")
        #expect(reply.phase == .sending)
        #expect(reply.attempts == 2)
    }

    @Test func doubleRetryTypesOnce() async {
        let rig = ReplyRig()
        let reply = rig.send("hello there")
        await rig.until("failed") { reply.phase == .failed }
        rig.terminal.log.removeAll()
        rig.reconnectHeld = true
        rig.outbox.retry(reply.id)
        rig.outbox.retry(reply.id)
        await rig.pause(5)
        rig.reconnectHeld = false
        await rig.until("enter") { rig.terminal.count("enter") >= 1 }
        await rig.pause(20)
        #expect(rig.terminal.count("type:hello there") == 1)
        #expect(rig.terminal.count("enter") == 1)
    }

    @Test func retryWithTextOnScreenOnlyPressesEnter() async {
        let rig = ReplyRig()
        let reply = rig.send("hello there")
        await rig.until("failed") { reply.phase == .failed }
        rig.terminal.log.removeAll()
        rig.terminal.textLines = ["> hello there"]
        rig.outbox.retry(reply.id)
        await rig.until("enter") { rig.terminal.count("enter") >= 1 }
        #expect(rig.terminal.log == ["enter"])
    }

    @Test func discardWhileWaitingInAutomationTypesNothing() async {
        let rig = ReplyRig()
        rig.terminal.held = true
        let reply = rig.send("hello there")
        await rig.pause(10)
        rig.outbox.discard(reply.id)
        rig.terminal.held = false
        await rig.pause(30)
        #expect(rig.terminal.log.isEmpty)
        #expect(rig.outbox.replies.isEmpty)
    }

    @Test func confirmDuringConfirmEnterStopsExtraEnter() async {
        let rig = ReplyRig(confirmEnterWait: .milliseconds(40))
        rig.terminal.frameLines = ["> hello there"]
        rig.terminal.textLines = ["> hello there"]
        rig.send("hello there")
        await rig.until("enter") { rig.terminal.count("enter") >= 1 }
        rig.items = [rig.user("u1", "hello there")]
        rig.outbox.feedChanged(rig.items)
        await rig.pause(100)
        #expect(rig.terminal.count("enter") == 1)
    }

    @Test func pushNowTwiceIsOneEscape() async {
        let rig = ReplyRig()
        rig.state = "working"
        let first = rig.send("alpha reply")
        await rig.until("typed") { rig.terminal.count("enter") >= 1 }
        // The screen doesn't show it yet, so this push keeps waiting for it.
        rig.outbox.pushNow()
        // A newer queued reply and a second tap while the first push still runs.
        let second = rig.send("beta reply")
        rig.outbox.pushNow()
        // Wait for the push itself (a fixed pause was too short on a busy machine), then make
        // sure no second escape follows.
        await rig.until("escaped") { rig.terminal.count("escape") >= 1 }
        await rig.pause(40)
        #expect(rig.terminal.count("escape") == 1)
        #expect(first.phase == .pushed)
        #expect(second.phase == .queued)
    }

    @Test func pushNowSkipsEnterWhenAgentDrainedQueue() async {
        let rig = ReplyRig()
        rig.state = "working"
        rig.send("alpha reply")
        await rig.until("typed") { rig.terminal.count("enter") >= 1 }
        rig.terminal.log.removeAll()
        rig.outbox.pushNow()
        await rig.until("escape") { rig.terminal.count("escape") == 1 }
        await rig.pause(40)
        #expect(rig.terminal.count("enter") == 0)
    }

    @Test func pushNowDuringRetryDoesNotDoubleType() async {
        let rig = ReplyRig()
        let failed = rig.send("alpha reply")
        await rig.until("failed") { failed.phase == .failed }
        rig.state = "working"
        let queued = rig.send("beta reply")
        rig.terminal.frameLines = ["> beta reply"]
        rig.terminal.log.removeAll()
        rig.reconnectHeld = true
        rig.outbox.retry(failed.id)
        rig.outbox.pushNow()
        await rig.pause(5)
        rig.reconnectHeld = false
        await rig.pause(40)
        #expect(rig.terminal.count("type:alpha reply") == 1)
        #expect(rig.terminal.count("type:beta reply") == 1)
        #expect(rig.terminal.count("escape") == 1)
        #expect(queued.phase == .pushed)
    }

    @Test func imagesConfirmAfterDeadlineWithoutFeedChange() async {
        let rig = ReplyRig()
        rig.send("", images: [rig.image()])
        await rig.until("typed") { rig.terminal.count("enter") >= 1 }
        #expect(rig.outbox.replies.count == 1)
        #expect(rig.outbox.replies[0].text == "1 image")
        await rig.until("given up") { rig.outbox.replies.isEmpty }
        #expect(rig.terminal.log.first == "paste:/tmp/pic.jpg")
    }

    @Test func workingAgentNeverFails() async {
        let rig = ReplyRig()
        rig.state = "working"
        let reply = rig.send("hello there")
        await rig.pause(50)
        #expect(reply.phase == .queued)
    }

    @Test func queuedTextOnScreenNeverFails() async {
        let rig = ReplyRig()
        rig.terminal.textLines = ["> hello there", "  queued"]
        let reply = rig.send("hello there")
        await rig.pause(50)
        #expect(reply.phase == .sending)
    }
}
