import Foundation
import HerdrKit
import TerminalCore
import UserNotifications

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

    /// What a typed reply ended up doing.
    enum ReplyOutcome: Equatable {
        /// Typed into the agent's prompt and sent.
        case sent
        /// The agent is waiting on a question or menu: the text is in the chat's draft and the chat is open.
        case savedAsDraft
        /// Couldn't connect, or nothing to send: the chat is open.
        case openedChat
    }

    /// A typed reply from an alert's Reply action (or "Send to agent"): typed into the agent's
    /// prompt and sent, once.
    @discardableResult
    func reply(_ request: ReplyNotificationRequest) async -> ReplyOutcome {
        let text = request.text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let screen = await replyScreen?(request) else {
            openChat(request.host, request.address)
            return .openedChat
        }
        // Typing into a permission or choice prompt would answer it (Enter picks the highlighted
        // option, a digit picks one): then the text waits in the chat's draft instead.
        guard Self.acceptsFreeText(status: screen.status, lines: screen.lines) else {
            await screen.close()
            let key = "\(request.host.uuidString)|\(request.address)"
            ReplyDrafts.restore([text], for: key, in: draftDefaults)
            openChat(request.host, request.address)
            return .savedAsDraft
        }
        await screen.send([.text(text), .enter])
        await screen.close()
        return .sent
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

    /// Starts the machine's session if needed and waits up to `timeout` for it to be connected and
    /// to list the terminal.
    static func connected(
        sessions: SessionStore, hosts: HostStore, keys: KeyLibrary, timeout: Duration = .seconds(15)
    ) -> (UUID, String) async -> (HostSession, Terminal)? {
        { hostID, address in
            guard let host = hosts.hosts.first(where: { $0.id == hostID }) else { return nil }
            let session = sessions.session(for: host)
            if session.state != .connected { session.start(keys: keys) }
            let start = ContinuousClock.now
            while ContinuousClock.now - start < timeout {
                if session.state == .connected, session.terminal(address) != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard session.state == .connected, let terminal = session.terminal(address), terminal.isLive
            else { return nil }
            return (session, terminal)
        }
    }

    /// The real thing: starts the machine's session if needed (unlocking its key, which may ask for
    /// Face ID: the app is in the foreground), waits up to `timeout` for it to be connected, then
    /// attaches to the terminal and reads its screen.
    static func live(
        sessions: SessionStore, hosts: HostStore, keys: KeyLibrary, timeout: Duration = .seconds(15)
    ) -> (UUID, String) async -> Screen? {
        let connect = connected(sessions: sessions, hosts: hosts, keys: keys, timeout: timeout)
        return { hostID, address in
            guard let (session, terminal) = await connect(hostID, address),
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

/// Posts a sealed answer to the relay's mailbox (POST /v1/answer); true when the relay took it.
struct RemoteAnswerSender {
    var relay: URL
    var secret: () -> String?
    var key: () -> Data?
    var post: (URLRequest) async -> Int?

    func send(machine: String, answerID: String, choice: PushAlertKey.AnswerChoice) async -> Bool {
        guard let secret = secret(), let key = key(),
              let body = RemoteAnswer.body(machine: machine, answerID: answerID, choice: choice, key: key) else { return false }
        var request = URLRequest(url: relay.appending(path: "v1/answer"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        return await post(request) == 204
    }

    static var live: RemoteAnswerSender {
        RemoteAnswerSender(
            relay: (UserDefaults.standard.dictionary(forKey: "bergr.push.secret")?["relay"] as? String)
                .flatMap(URL.init(string:)) ?? PushRegistration.relayURL,
            secret: { UserDefaults.standard.dictionary(forKey: "bergr.push.secret")?["secret"] as? String },
            key: { PushAlertKey.stored() },
            post: { request in
                (try? await URLSession.shared.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
            })
    }
}

/// Where a notification button's answer goes: through the relay to the helper when the alert has an
/// answerID and the helper is new enough, else (or when the post fails) the old path that opens the app.
@MainActor
struct RemoteAnswerRoute {
    enum Outcome: Equatable { case relayed, foreground }

    var helperVersion: (UUID) -> Int?
    var send: (_ machine: String, _ answerID: String, _ choice: PushAlertKey.AnswerChoice) async -> Bool
    var foreground: (AnswerNotificationRequest) -> Void
    /// Told when the relay post failed, so the user knows to open Bergr.
    var failed: (AnswerNotificationRequest) -> Void = { _ in }

    @discardableResult
    func run(_ request: AnswerNotificationRequest) async -> Outcome {
        guard RemoteAnswer.usesRelay(request, helperVersion: helperVersion(request.host)),
              let id = request.answerID, let machine = request.machine,
              let choice = RemoteAnswer.choice(question: request.question, index: request.index) else {
            foreground(request)
            return .foreground
        }
        if await send(machine, id, choice) { return .relayed }
        failed(request)
        foreground(request)
        return .foreground
    }

    static let live = RemoteAnswerRoute(
        helperVersion: { RemoteAnswer.helperVersion($0) },
        send: { await RemoteAnswerSender.live.send(machine: $0, answerID: $1, choice: $2) },
        foreground: { AnswerNotifications.shared.handleForeground($0) },
        failed: { request in
            let content = UNMutableNotificationContent()
            content.title = "Couldn't send the answer"
            content.body = "Open Bergr to answer."
            content.userInfo = ["host": request.host.uuidString, "address": request.address]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "bergr.answer.failed.\(request.address)", content: content, trigger: nil))
        })
}

/// Receives the notification buttons' answers. They can arrive before the root view has set the
/// flow up (a tap that launched the app), so they wait for it.
@MainActor
final class AnswerNotifications {
    static let shared = AnswerNotifications()
    var route: RemoteAnswerRoute = .live
    private var flow: AnswerFlow?
    private var queued: [AnswerNotificationRequest] = []
    private var queuedReplies: [ReplyNotificationRequest] = []

    static func install() {
        AnswerNotificationBridge.handler = { await shared.handle($0) }
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

    private func handle(_ request: AnswerNotificationRequest) async {
        let route = route
        await route.run(request)
    }

    /// The old path: connect over SSH (the app is opened for it), check the screen, press.
    func handleForeground(_ request: AnswerNotificationRequest) {
        guard let flow else { return queued.append(request) }
        Task { await flow.run(request) }
    }
}

#if os(iOS)
/// Live Activity / Watch buttons (AnswerPromptIntent) through the relay.
extension RemoteAnswer {
    /// Only Yes or No (the y / n key, or a numbered choice's label starting with it); nil keeps SSH.
    nonisolated static func intentChoice(_ request: AnswerRequest) -> PushAlertKey.AnswerChoice? {
        switch request.key {
        case "y": return .yes
        case "n": return .no
        case "": break
        default: return nil
        }
        let label = request.label.lowercased()
        if label.hasPrefix("yes") { return .yes }
        if label.hasPrefix("no") { return .no }
        return nil
    }

    /// The latest answerID an alert for this terminal left (10 minutes), unless the helper is known
    /// to be older. The helper re-checks turn, question and screen, so a stale one only gets refused.
    nonisolated static func intentAnswer(
        _ request: AnswerRequest, helperVersion: Int?, latest: (String, String) -> String?
    ) -> (id: String, choice: PushAlertKey.AnswerChoice)? {
        guard let choice = intentChoice(request), helperVersion.map({ $0 >= minHelperVersion }) ?? true,
              let id = latest(request.host, request.address) else { return nil }
        return (id, choice)
    }

    /// Sends a Live Activity / Watch answer through the relay; false keeps the SSH path.
    @MainActor
    static func sendIntent(_ request: AnswerRequest, sender: RemoteAnswerSender = .live) async -> Bool {
        let version = UUID(uuidString: request.host).flatMap { helperVersion($0) }
        guard let (id, choice) = intentAnswer(request, helperVersion: version, latest: { latest(machine: $0, address: $1) })
        else { return false }
        return await sender.send(machine: request.host, answerID: id, choice: choice)
    }
}
#endif
