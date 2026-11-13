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
        // A dangerous command is never answered from a button: the chat asks for a confirmation.
        guard DangerousCommand.check(([now.question] + AnswerParser.context(in: lines)).joined(separator: "\n")) == nil
        else { return .changed }
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

/// Logs an answer in the approvals log and puts it into the terminal's chat, if it has one.
@MainActor
enum AnswerRecorder {
    static func record(
        question: String, answer: String, session: HostSession, terminal: Terminal, source: ApprovalEntry.Source
    ) {
        let host = session.host
        ApprovalLog.record(
            machine: host.name.isEmpty ? host.target.host : host.name,
            agent: terminal.status?.app ?? terminal.displayName, question: question, answer: answer, source: source)
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

/// Answering from a notification's buttons. The action opens the app (the key may need Face ID and
/// is forgotten in the background), which connects to the machine, checks that the same question is
/// still on screen and only then presses the answer; otherwise it opens the chat.
enum AnswerNotificationPolicy {
    /// What to press, or `.changed` when the agent isn't blocked on the same question any more.
    static func decide(
        _ request: AnswerNotificationRequest, status: TerminalStatus?, lines: [String]?
    ) -> AnswerDecision {
        guard status?.state == "blocked", let lines else { return .changed }
        // The alert's question is the status text it was made from; a new one is a new question.
        let asked = request.question.title
        guard asked == status?.msg || asked == status?.title else { return .changed }
        let label = request.question.options[request.index]
        let reading = PromptReading.read(lines: lines, statusTitle: status?.title)
        // A numbered (or ❯-cursor) menu: Yes is the first option starting with "Yes" (not "don't
        // ask again"), No the first starting with "No"; answered like the answer cards do.
        if request.question.keys, reading.numbered {
            let word = label.lowercased()
            let choices = AnswerParser.choices(in: lines)
            guard word == "yes" || word == "no",
                  let choice = choices.first(where: { $0.label.lowercased().hasPrefix(word) }) else { return .changed }
            return AnswerPolicy.decide(
                question: reading.question, number: choice.number, label: choice.label, key: "",
                lines: lines, statusTitle: status?.title)
        }
        return AnswerPolicy.decide(
            question: reading.question, number: request.question.keys ? 0 : request.index + 1, label: label,
            key: request.question.keys ? key(for: label) : "", lines: lines, statusTitle: status?.title)
    }

    static func key(for label: String) -> String {
        switch label.lowercased() {
        case "yes": "y"
        case "no": "n"
        case "esc": "esc"
        default: ""
        }
    }
}

/// One answer's steps, with the connection and the terminal behind closures so it can be tested.
@MainActor
struct AnswerFlow {
    /// A terminal's screen and status after connecting, and how to press keys on it.
    struct Screen {
        var status: TerminalStatus?
        var lines: [String]?
        var send: ([PromptStep]) async -> Void
        var record: (_ question: String, _ answer: String) -> Void
        var close: () async -> Void
    }

    var screen: (AnswerNotificationRequest) async -> Screen?
    var openChat: (_ host: UUID, _ address: String) -> Void
    /// Connects for a typed reply; nil means replies just open the chat.
    var replyScreen: ((ReplyNotificationRequest) async -> Screen?)? = nil

    /// A typed reply from an alert's Reply action: typed into the agent's prompt and sent, once.
    func reply(_ request: ReplyNotificationRequest) async {
        let text = request.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let screen = await replyScreen?(request) else {
            openChat(request.host, request.address)
            return
        }
        // Typing into a permission or choice prompt would answer it (Enter picks the highlighted
        // option, a digit picks one): then the text waits in the chat's draft instead.
        guard Self.acceptsFreeText(status: screen.status, lines: screen.lines) else {
            await screen.close()
            let key = "\(request.host.uuidString)|\(request.address)"
            ReplyDrafts.restore([text], for: key, in: draftDefaults)
            openChat(request.host, request.address)
            return
        }
        await screen.send([.text(text), .enter])
        await screen.close()
    }

    /// Where a reply that couldn't be typed is kept (tests use their own).
    var draftDefaults: UserDefaults = .standard

    /// Whether the agent is waiting for free text: not blocked on a prompt, and no menu on screen.
    static func acceptsFreeText(status: TerminalStatus?, lines: [String]?) -> Bool {
        guard status?.state != "blocked", let lines else { return false }
        return AnswerParser.choices(in: lines).isEmpty
    }

    func run(_ request: AnswerNotificationRequest) async {
        guard let screen = await screen(request) else {
            openChat(request.host, request.address)
            return
        }
        let decision = AnswerNotificationPolicy.decide(request, status: screen.status, lines: screen.lines)
        if case .send(let steps, let question, let answer) = decision {
            await screen.send(steps)
            screen.record(question, answer)
        } else {
            openChat(request.host, request.address)
        }
        await screen.close()
    }

    /// The real thing: starts the machine's session if needed (unlocking its key, which may ask for
    /// Face ID: the app is in the foreground), waits up to `timeout` for it to be connected, then
    /// attaches to the terminal and reads its screen.
    static func live(
        sessions: SessionStore, hosts: HostStore, keys: KeyLibrary, timeout: Duration = .seconds(15)
    ) -> (UUID, String) async -> Screen? {
        { hostID, address in
            guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return nil }
            let session = sessions.session(for: host)
            if session.state != .connected { session.start(keys: keys) }
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                if session.state == .connected, session.terminal(address) != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard session.state == .connected, let terminal = session.terminal(address), terminal.isLive,
                  let capture = try? await ScreenCapture.open(session: session, terminal: terminal, observe: false)
            else { return nil }
            let lines = await capture.settledLines()
            return Screen(
                // The status may have moved on while we attached.
                status: session.terminal(address)?.status, lines: lines,
                send: { await capture.send($0) },
                record: {
                    AnswerRecorder.record(
                        question: $0, answer: $1, session: session, terminal: terminal, source: .notification)
                },
                close: { await capture.close() })
        }
    }
}

/// Receives the notification buttons' answers. They can arrive before the root view has set the
/// flow up (a tap that launched the app), so they wait for it.
@MainActor
final class AnswerNotifications {
    static let shared = AnswerNotifications()
    private var flow: AnswerFlow?
    private var queued: [AnswerNotificationRequest] = []
    private var queuedReplies: [ReplyNotificationRequest] = []

    static func install() {
        AnswerNotificationBridge.handler = { shared.handle($0) }
        AnswerNotificationBridge.replyHandler = { shared.handleReply($0) }
    }

    func configure(_ flow: AnswerFlow) {
        self.flow = flow
        let waiting = queued
        queued = []
        for request in waiting { Task { await flow.run(request) } }
        let replies = queuedReplies
        queuedReplies = []
        for request in replies { Task { await flow.reply(request) } }
    }

    private func handleReply(_ request: ReplyNotificationRequest) {
        guard let flow else { return queuedReplies.append(request) }
        Task { await flow.reply(request) }
    }

    private func handle(_ request: AnswerNotificationRequest) {
        guard let flow else { return queued.append(request) }
        Task { await flow.run(request) }
    }
}
