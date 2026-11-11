import Foundation
import HerdrKit
import SwiftUI
import TerminalCore

/// What a reply says, and how to tell the conversation (or the screen) has it.
struct ReplyPayload: Equatable {
    let text: String
    let hasImages: Bool
    /// The user messages the conversation already had when this was sent: an earlier "yes"
    /// mustn't confirm a new one.
    var known: Set<String> = []

    /// Whether the conversation has this reply as a message that came after it was sent.
    func arrived(in items: [ChatFeed.Item]) -> Bool {
        let said = Set(items.suffix(20).compactMap { item -> String? in
            guard !known.contains(item.id), case .user(let text) = item.kind else { return nil }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        })
        return isIn(said)
    }

    /// Whether the conversation has this reply. With images it comes back with the image
    /// paths (or "[Image #1]") in front of the words, so the words only have to end it.
    func isIn(_ said: Set<String>) -> Bool {
        if said.contains(text) { return true }
        // Sent twice in one message (a retry after the first copy reached the prompt).
        if text.count >= 12, said.contains(where: { $0.contains(text) }) { return true }
        return hasImages && !text.isEmpty && said.contains { $0.hasSuffix(text) }
    }

    /// Whether the terminal's screen shows the reply: the start of its first line, enough to
    /// tell it apart, on one row (a long reply wraps).
    static func onScreen(_ text: String, lines: [String]) -> Bool {
        let first = text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !first.isEmpty else { return false }
        let probe = String(first.prefix(24))
        return lines.contains { $0.contains(probe) }
    }
}

/// The terminal a reply is typed into.
@MainActor protocol ReplyTerminal: AnyObject {
    var textLines: [String] { get }
    /// The drawn frame's lines: kept separate from `textLines` on purpose (they update at different times).
    var frameLines: [String] { get }
    func automate(_ steps: @escaping @MainActor () async -> Void) async
    func type(_ text: String)
    func paste(_ text: String)
    func press(_ key: TerminalKey)
}

extension TerminalScreenModel: ReplyTerminal {
    var frameLines: [String] { frame.textLines }
    func press(_ key: TerminalKey) { press(key, modifiers: [], text: nil) }
}

struct ReplyTiming {
    var enterDelay: Duration = .milliseconds(150)
    var shellBangDelay: Duration = .milliseconds(120)
    var confirmEnterWait: Duration = .milliseconds(2500)
    var confirmEnterTries = 2
    var firstCheck: Duration = .seconds(10)
    var recheck: Duration = .seconds(5)
    var imagesGiveUp: Duration = .seconds(20)
    var stopWait: Duration = .seconds(3)
    /// How often the screen or the agent's state is looked at while waiting.
    var poll: Duration = .milliseconds(100)
    /// The pause after the agent stopped, for its prompt to take input.
    var stoppedSettle: Duration = .milliseconds(250)
}

struct ReplyEnvironment {
    var terminal: any ReplyTerminal
    /// The agent's state, read fresh from the session.
    var agentState: @MainActor () -> String?
    var feedItems: @MainActor () -> [ChatFeed.Item]
    /// Uploads an image and returns the path it has on the machine.
    var upload: @MainActor (Data) async throws -> String
    /// Reconnects from scratch, as reopening the app does.
    var reconnect: @MainActor () async -> Void
    var timing = ReplyTiming()
}

/// One sent reply. Exactly one driver task works on it at a time; every restart (retry, discard,
/// confirmation) bumps `epoch`, so a task that was already waiting never types for a newer one.
@Observable final class ReplyDelivery: Identifiable {
    enum Phase: Equatable { case sending, queued, pushed, failed, confirmed }
    let id = UUID()
    let payload: ReplyPayload
    private(set) var phase: Phase
    private(set) var sentAt = Date.now
    private(set) var attempts = 1
    var text: String { payload.text }

    @ObservationIgnored fileprivate var epoch = 0
    @ObservationIgnored fileprivate var driver: Task<Void, Never>?

    fileprivate init(payload: ReplyPayload, phase: Phase) {
        self.payload = payload
        self.phase = phase
    }

    fileprivate func set(_ phase: Phase) { self.phase = phase }
    fileprivate func restarted() { sentAt = .now; attempts += 1; phase = .sending }
}

/// The replies sent from one chat, until the conversation has them.
@Observable final class ReplyOutbox {
    private(set) var replies: [ReplyDelivery] = []
    @ObservationIgnored var environment: ReplyEnvironment?
    /// For the bubble turning to "Not delivered" by itself.
    @ObservationIgnored var motion: Animation?
    @ObservationIgnored private var pushTask: Task<Void, Never>?

    /// Replies to draw: the ones the conversation doesn't have yet. A reply it has is drawn as the
    /// real message from the same update: never both for a frame.
    func shown(in items: [ChatFeed.Item], search: String?) -> [ReplyDelivery] {
        let waiting = replies.filter { !$0.payload.arrived(in: items) }
        guard let search else { return waiting }
        return waiting.filter { $0.text.localizedStandardContains(search) }
    }

    @discardableResult
    func send(text: String, images: [ChatAttachment], interrupting: Bool,
              onUploadFailure: @escaping @MainActor (Error) -> Void) -> ReplyDelivery? {
        guard let env = environment else { return nil }
        var payload = ReplyPayload(text: text.isEmpty ? "\(images.count) image\(images.count == 1 ? "" : "s")" : text,
                                   hasImages: !images.isEmpty)
        payload.known = Set(env.feedItems().compactMap { if case .user = $0.kind { $0.id } else { nil } })
        let working = env.agentState() == "working"
        let reply = ReplyDelivery(payload: payload, phase: working ? (interrupting ? .pushed : .queued) : .sending)
        replies.append(reply)
        let epoch = reply.epoch
        reply.driver = Task {
            await deliver(reply, epoch: epoch, text: text, images: images, interrupting: interrupting,
                          env: env, onUploadFailure: onUploadFailure)
        }
        return reply
    }

    /// Stops the agent so the replies waiting in its queue are read now. Claude Code puts queued
    /// messages back in its prompt when interrupted; Return sends them (on an empty prompt it does nothing).
    /// A second tap while this runs is ignored.
    func pushNow() {
        guard pushTask == nil, let env = environment else { return }
        let targets = replies.filter { $0.phase == .queued }
        guard !targets.isEmpty else { return }
        for reply in targets { reply.set(.pushed) }
        let epochs = targets.map(\.epoch)
        let timing = env.timing
        let terminal = env.terminal
        pushTask = Task {
            await terminal.automate {
                terminal.press(.escape)
                // Return only once the queued text is back in the prompt: Claude Code takes a moment
                // to stop, and a Return before then lands on an empty prompt (a second tap was needed).
                // Replies discarded or restarted meanwhile don't count.
                @MainActor func shows() -> Bool {
                    let bottom = terminal.frameLines.suffix(12).joined(separator: " ")
                    return zip(targets, epochs).contains {
                        $0.0.epoch == $0.1 && bottom.contains(String($0.0.text.prefix(24)))
                    }
                }
                let end = ContinuousClock.now + timing.stopWait
                while ContinuousClock.now < end, !shows() {
                    try? await Task.sleep(for: timing.poll)
                }
                try? await Task.sleep(for: timing.enterDelay)
                // An agent that sends its queue by itself once stopped: nothing to press.
                guard shows() else { return }
                terminal.press(.enter)
            }
            pushTask = nil
        }
    }

    /// Reconnects from scratch and sends the reply again.
    func retry(_ id: ReplyDelivery.ID) {
        guard let env = environment, let reply = replies.first(where: { $0.id == id }) else { return }
        let epoch = restart(reply)
        reply.restarted()
        reply.driver = Task {
            await env.reconnect()
            guard reply.epoch == epoch else { return }
            // The words may already be in the prompt, typed before the line died with Enter lost:
            // typing them again would send them twice in one message. Submit what's there.
            await env.terminal.automate {
                guard reply.epoch == epoch else { return }
                if !ReplyPayload.onScreen(reply.text, lines: env.terminal.textLines) {
                    env.terminal.type(reply.text)
                    try? await Task.sleep(for: env.timing.enterDelay)
                    guard reply.epoch == epoch else { return }
                }
                env.terminal.press(.enter)
            }
            guard reply.epoch == epoch else { return }
            await monitor(reply, epoch: epoch, since: .now, env: env)
        }
    }

    func discard(_ id: ReplyDelivery.ID) {
        guard let reply = replies.first(where: { $0.id == id }) else { return }
        remove(reply)
    }

    /// A reply the conversation has now is confirmed.
    func feedChanged(_ items: [ChatFeed.Item]) {
        for reply in replies where reply.payload.arrived(in: items) {
            reply.set(.confirmed)
            remove(reply)
        }
    }

    /// The chat went away: nothing may type for it any more.
    func cancelAll() {
        for reply in replies { _ = restart(reply) }
        replies = []
        pushTask?.cancel()
        pushTask = nil
    }

    // MARK: Driving

    private func restart(_ reply: ReplyDelivery) -> Int {
        reply.epoch += 1
        reply.driver?.cancel()
        reply.driver = nil
        return reply.epoch
    }

    private func remove(_ reply: ReplyDelivery) {
        _ = restart(reply)
        replies.removeAll { $0 === reply }
    }

    private func deliver(_ reply: ReplyDelivery, epoch: Int, text: String, images: [ChatAttachment],
                         interrupting: Bool, env: ReplyEnvironment,
                         onUploadFailure: @MainActor (Error) -> Void) async {
        var paths: [String] = []
        do {
            for image in images {
                let path = try await env.upload(image.data)
                guard reply.epoch == epoch else { return }
                paths.append(path)
            }
        } catch {
            // Nothing is typed; the reply goes away so it can be sent again.
            guard reply.epoch == epoch else { return }
            remove(reply)
            onUploadFailure(error)
            return
        }
        let message = (paths + (text.isEmpty ? [] : [text])).joined(separator: " ")
        let terminal = env.terminal
        let timing = env.timing
        let sentPaths = paths
        await terminal.automate {
            guard reply.epoch == epoch else { return }
            if interrupting {
                terminal.press(.escape)
                // Type only once the agent has stopped (its screen says so), or it's queued again.
                let end = ContinuousClock.now + timing.stopWait
                while ContinuousClock.now < end, reply.epoch == epoch, env.agentState() == "working" {
                    try? await Task.sleep(for: timing.poll)
                }
                try? await Task.sleep(for: timing.stoppedSettle)
                guard reply.epoch == epoch else { return }
            }
            // Image paths go first, pasted as the terminal would get them; the agents attach them.
            if sentPaths.isEmpty, !message.contains("\n"), message.hasPrefix("!"), message.count > 1 {
                // A shell command: `!` on its own switches the agent's input to shell mode first
                // (as typing it does), then the command.
                terminal.type("!")
                try? await Task.sleep(for: timing.shellBangDelay)
                guard reply.epoch == epoch else { return }
                terminal.type(String(message.dropFirst()))
            } else if !sentPaths.isEmpty || message.contains("\n") {
                terminal.paste(message)
            } else {
                terminal.type(message)
            }
            // Return on its own, a moment later, so the agent sees it as "send" and not as part of the text.
            try? await Task.sleep(for: timing.enterDelay)
            guard reply.epoch == epoch else { return }
            terminal.press(.enter)
        }
        guard reply.epoch == epoch else { return }
        await confirmEnter(reply, epoch: epoch, message: message, env: env)
        guard reply.epoch == epoch else { return }
        await monitor(reply, epoch: epoch, since: reply.sentAt, env: env)
    }

    /// A Return can be lost (sent on a channel that was being replaced as the app came back): the
    /// text sits in the agent's input, unsent. If after a moment the reply isn't in the
    /// conversation and its text is still on the input's last lines, Return again (twice at most).
    private func confirmEnter(_ reply: ReplyDelivery, epoch: Int, message: String, env: ReplyEnvironment) async {
        let probe = String(message.replacingOccurrences(of: "\n", with: " ").prefix(24))
        guard probe.count >= 3 else { return }
        for _ in 0..<env.timing.confirmEnterTries {
            try? await Task.sleep(for: env.timing.confirmEnterWait)
            guard reply.epoch == epoch else { return }
            if env.agentState() == "working" { return }
            guard env.terminal.frameLines.suffix(6).contains(where: { $0.contains(probe) }) else { return }
            env.terminal.press(.enter)
        }
    }

    /// Ten seconds without the reply in the conversation, without the agent working, and without
    /// the words on the terminal's screen (an agent shows a queued reply under its prompt): it most
    /// likely never arrived (a channel that died quietly), so the bubble offers Retry. While the
    /// agent works or the screen shows it, it keeps watching: the agent reads it after this step.
    /// A reply with images comes back worded differently ("[Image #1] …"): it goes after a while.
    private func monitor(_ reply: ReplyDelivery, epoch: Int, since: Date, env: ReplyEnvironment) async {
        func remaining(_ limit: Duration, from start: Date) -> Duration {
            max(.zero, limit - .seconds(Date.now.timeIntervalSince(start)))
        }
        if reply.payload.hasImages {
            try? await Task.sleep(for: remaining(env.timing.imagesGiveUp, from: reply.sentAt))
            guard reply.epoch == epoch else { return }
            remove(reply)
            return
        }
        try? await Task.sleep(for: remaining(env.timing.firstCheck, from: since))
        while reply.epoch == epoch {
            if env.agentState() != "working", !ReplyPayload.onScreen(reply.text, lines: env.terminal.textLines) {
                reply.driver = nil
                withAnimation(motion) { reply.set(.failed) }
                return
            }
            try? await Task.sleep(for: env.timing.recheck)
        }
    }
}
