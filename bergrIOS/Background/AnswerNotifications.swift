import Foundation
import HerdrKit

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
        await screen.send([.text(text), .enter])
        await screen.close()
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
                    LiveActivityController.record(
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
