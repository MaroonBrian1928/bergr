import Foundation
import HerdrKit
import TerminalCore

/// The question on a terminal's screen and the answers to offer for it. Pure: the Live Activity
/// content and the tap's re-check both come from here, so they agree on what "the same prompt" is.
struct PromptReading: Equatable {
    typealias Option = BergrActivityAttributes.Option

    let question: String
    let options: [Option]
    /// Numbered choices from the screen; false for the Yes / No / Esc fallback.
    let numbered: Bool

    static let maxOptions = 4

    static func read(lines: [String], statusTitle: String?) -> PromptReading {
        let choices = AnswerParser.choices(in: lines)
        if !choices.isEmpty {
            return PromptReading(
                question: AnswerParser.question(in: lines) ?? statusTitle ?? "Waiting for you",
                options: choices.prefix(maxOptions).map { Option(number: $0.number, label: $0.label, key: "") },
                numbered: true)
        }
        let asked = lines.last(where: { $0.contains("?") }).map(AnswerParser.clean)
        // Nothing asked (e.g. Claude signed out): no buttons, since Yes/No would type into its input.
        if asked == nil || AnswerParser.needsLogin(in: lines) {
            return PromptReading(question: statusTitle ?? "Waiting for you", options: [], numbered: false)
        }
        return PromptReading(
            question: asked ?? statusTitle ?? "Waiting for you",
            options: [
                Option(number: 0, label: "Yes", key: "y"),
                Option(number: 0, label: "No", key: "n"),
                Option(number: 0, label: "Esc", key: "esc"),
            ],
            numbered: false)
    }
}

enum PromptStep: Equatable {
    case up, down, enter, escape
    case text(String)
}

enum AnswerDecision: Equatable {
    /// Still the same prompt: press these keys, then record `answer` for `question` in the chat.
    case send(steps: [PromptStep], question: String, answer: String)
    /// The prompt is gone or different: press nothing.
    case changed
}

enum AnswerPolicy {
    /// Whether the question the button was made for is still the one on screen, and what to press.
    static func decide(
        question: String, number: Int, label: String, key: String, lines: [String], statusTitle: String?
    ) -> AnswerDecision {
        let now = PromptReading.read(lines: lines, statusTitle: statusTitle)
        guard now.question == question, !now.options.isEmpty else { return .changed }
        if key.isEmpty {
            guard now.numbered else { return .changed }
            let choice = AnswerChoice(number: number, label: label, selected: false)
            guard AnswerParser.isStillShown(choice, in: lines) else { return .changed }
            let steps = AnswerParser.steps(to: choice, in: AnswerParser.choices(in: lines))
            let context = AnswerParser.context(in: lines)
            let asked = ([question] + context.suffix(1)).joined(separator: " — ")
            return .send(
                steps: Array(repeating: steps > 0 ? PromptStep.down : .up, count: abs(steps)) + [.enter],
                question: asked, answer: label)
        }
        // Yes / No / Esc only answer a prompt without numbered choices.
        guard !now.numbered else { return .changed }
        switch key {
        case "y": return .send(steps: [.text("y")], question: question, answer: "Yes")
        case "n": return .send(steps: [.text("n")], question: question, answer: "No")
        case "esc": return .send(steps: [.escape], question: question, answer: "Canceled (esc)")
        default: return .changed
        }
    }
}

/// The most urgent blocked agent, with its question and answers.
enum PromptBuilder {
    typealias Prompt = BergrActivityAttributes.Prompt

    /// Blocked agents with a numbered question first (those can be answered precisely), then in
    /// the order given. An agent whose screen isn't known yet is skipped.
    static func prompt(machines: [LiveActivityMachine], screens: [String: [String]]) -> Prompt? {
        var best: (prompt: Prompt, numbered: Bool)?
        for machine in machines {
            for terminal in machine.terminals where terminal.isLive && terminal.status?.state == "blocked" {
                guard let lines = screens[LiveActivityController.screenKey(host: machine.host, terminal: terminal)]
                else { continue }
                let reading = PromptReading.read(lines: lines, statusTitle: terminal.status?.title)
                if reading.options.isEmpty { continue }
                let prompt = Prompt(
                    host: machine.host.uuidString, address: terminal.address, title: terminal.displayName,
                    question: reading.question, options: reading.options)
                if best == nil || (reading.numbered && !best!.numbered) { best = (prompt, reading.numbered) }
            }
        }
        return best?.prompt
    }
}

// MARK: Screen access

/// A terminal's screen, read through a channel of our own: feeds the output into an emulator.
@MainActor
final class ScreenCapture {
    let attached: AttachedTerminal
    private let vt: VirtualTerminal
    private var pump: Task<Void, Never>?
    private var lastChunk: ContinuousClock.Instant?

    /// Attaches headless; `observe` watches without taking the size (reading), a viewer can type.
    static func open(session: HostSession, terminal: Terminal, observe: Bool) async throws -> ScreenCapture {
        let attached = try await session.attach(
            address: terminal.address, cols: max(terminal.cols, 1), rows: max(terminal.rows, 1),
            history: 0, observe: observe, display: nil)
        do { return try ScreenCapture(attached) } catch {
            await attached.detach()
            throw error
        }
    }

    private init(_ attached: AttachedTerminal) throws {
        self.attached = attached
        vt = try VirtualTerminal(cols: max(attached.terminal.cols, 1), rows: max(attached.terminal.rows, 1))
        pump = Task { [weak self] in
            do {
                for try await chunk in attached.output {
                    guard let self else { return }
                    self.vt.write(chunk)
                    self.lastChunk = .now
                    await attached.consumed(bytes: chunk.count)
                    let replies = self.vt.takeReplies()
                    if !replies.isEmpty { try? await attached.sendAutomatic(replies) }
                }
            } catch {}
        }
    }

    /// The screen once output has been quiet for a moment (at most `limit`); nil if nothing came.
    func settledLines(limit: Duration = .seconds(3)) async -> [String]? {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < limit {
            try? await Task.sleep(for: .milliseconds(120))
            if let last = lastChunk, ContinuousClock.now - last > .milliseconds(300) { break }
        }
        guard lastChunk != nil else { return nil }
        return vt.frame().textLines
    }

    func send(_ steps: [PromptStep]) async {
        try? await attached.focus(true)
        for step in steps {
            let data: Data
            switch step {
            case .up: data = vt.encode(.up)
            case .down: data = vt.encode(.down)
            case .enter: data = vt.encode(.enter)
            case .escape: data = vt.encode(.escape)
            case .text(let text): data = Data(text.utf8)
            }
            try? await attached.send(data)
        }
    }

    func close() async {
        pump?.cancel()
        pump = nil
        await attached.detach()
    }
}

extension LiveActivityController {
    /// Reads a blocked terminal's screen without taking its size or typing.
    static func readScreen(session: HostSession, terminal: Terminal) async -> [String]? {
        guard let capture = try? await ScreenCapture.open(session: session, terminal: terminal, observe: true)
        else { return nil }
        let lines = await capture.settledLines()
        await capture.close()
        return lines
    }

    /// A tap on an answer button: re-reads the screen and answers only if it still asks the
    /// same question. Never answers a prompt that has changed.
    func answer(_ request: AnswerRequest) async {
        defer { screenAnswered(host: request.host, address: request.address) }
        guard let host = UUID(uuidString: request.host), let session = sessions.existing(host),
              let terminal = session.terminal(request.address), terminal.isLive,
              terminal.status?.state == "blocked",
              let capture = try? await ScreenCapture.open(session: session, terminal: terminal, observe: false)
        else { return }
        let lines = await capture.settledLines()
        var decision = AnswerDecision.changed
        if let lines {
            // The status may have moved on while we attached.
            let status = session.terminal(request.address)?.status
            if status?.state == "blocked" {
                decision = AnswerPolicy.decide(
                    question: request.question, number: request.number, label: request.label, key: request.key,
                    lines: lines, statusTitle: status?.title)
            }
        }
        if case .send(let steps, let question, let answer) = decision {
            await capture.send(steps)
            Self.record(question: question, answer: answer, session: session, terminal: terminal)
        }
        await capture.close()
    }

    /// Puts the answer into the terminal's chat, if it has an agent chat.
    static func record(question: String, answer: String, session: HostSession, terminal: Terminal) {
        guard let agent = ChatAgent.detect(terminal) else { return }
        let front = terminal.foreground.flatMap { fg in
            ChatAgent.detect(name: fg.name, argv: fg.argv) == agent ? fg : nil
        }
        session.chatFeed(
            address: terminal.address, agent: agent, pid: front?.pid ?? 0, cwd: front?.cwd ?? terminal.cwd,
            sessionHint: ChatAgent.sessionHint(argv: front?.argv ?? terminal.foreground?.argv ?? []))
            .recordDecision(question: question, answer: answer)
    }
}
