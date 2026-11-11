import Foundation
import HerdrKit

/// A coding agent whose conversation Bergr can show as a chat.
enum ChatAgent: String, Sendable {
    case claude, codex, antigravity

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        }
    }

    /// From what herdr-core knows: the agent's own status report, else the foreground program.
    static func detect(_ terminal: Terminal) -> ChatAgent? {
        var names: [String] = []
        if let app = terminal.status?.app { names.append(app) }
        if let fg = terminal.foreground {
            names.append(fg.name)
            names += fg.argv.prefix(3).map { ($0 as NSString).lastPathComponent }
        }
        return match(names)
    }

    static func detect(name: String, argv: [String]) -> ChatAgent? {
        match([name] + argv.prefix(3).map { ($0 as NSString).lastPathComponent })
    }

    /// The session ID in the agent's launch command (a resumed conversation), if any:
    /// `claude --resume <id>`, `-r <id>`, `--session-id <id>`, `codex resume <id>`.
    static func sessionHint(argv: [String]) -> String? {
        let names = argv.prefix(3).map { ($0 as NSString).lastPathComponent.lowercased() }
        func valid(_ v: String) -> String? {
            !v.isEmpty && !v.hasPrefix("-") && v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) ? v : nil
        }
        if names.contains(where: { $0.hasPrefix("claude") }) {
            for (i, arg) in argv.enumerated() {
                if ["--resume", "-r", "--session-id"].contains(arg), i + 1 < argv.count,
                   let v = valid(argv[i + 1]) { return v }
                for flag in ["--resume=", "--session-id="] where arg.hasPrefix(flag) {
                    if let v = valid(String(arg.dropFirst(flag.count))) { return v }
                }
            }
        }
        if let at = names.firstIndex(where: { $0.hasPrefix("codex") }), at + 2 < argv.count,
           argv[at + 1] == "resume" {
            return valid(argv[at + 2])
        }
        return nil
    }

    private static func match(_ names: [String]) -> ChatAgent? {
        for name in names.map({ $0.lowercased() }) {
            if name.hasPrefix("claude") { return .claude }
            if name.hasPrefix("codex") { return .codex }
            if name.hasPrefix("antigravity") || name == "agy" { return .antigravity }
        }
        return nil
    }
}

/// One terminal agent's conversation, read on the host by `agent-feed.py` over SSH.
@Observable
@MainActor
final class ChatFeed {
    struct Item: Identifiable, Equatable {
        let id: String
        var kind: Kind
    }

    enum Kind: Equatable {
        case user(String)
        case assistant(text: String, blocks: [MarkdownBlock])
        case tool(name: String, summary: String)
        /// The agent's task list (Claude's TodoWrite, Codex's update_plan), latest version.
        case plan([PlanStep])
        /// An image in the conversation; `fromUser` puts it on the user's side.
        case image(data: Data, fromUser: Bool)
        /// An image still on its way (a conversation's history sends the text first): its size,
        /// when the header gave it, so the placeholder takes the image's place without a jump.
        case imageLoading(width: Double?, height: Double?, fromUser: Bool)
        /// An answer given from the chat to an agent's question or approval prompt. Agents don't
        /// write these to their files, so the app keeps them.
        case decision(question: String, answer: String)
        /// A line from the agent's tooling, not its reply (e.g. Codex citing its memory).
        case note(String)
        /// The agent asks the user to pick an option (Codex's request_user_input); answered by replying.
        case question(title: String, options: [String])
    }

    struct PlanStep: Equatable, Sendable {
        let text: String
        /// pending, in_progress or completed.
        let status: String
    }

    enum Phase: Equatable {
        case loading
        case live
        case noConversation
        case failed(String)
    }

    /// How full the agent's context is, and its plan limits where the agent saves them (Codex).
    struct Usage: Equatable {
        struct Window: Equatable {
            let percent: Double
            let resetsAt: Date?
        }
        var model: String?
        var effort: String?
        /// The permission mode as the agent's settings name it (Antigravity: "accept-edits").
        var mode: String? = nil
        var used: Int
        var limit: Int?
        var session: Window?
        var weekly: Window?

        var fraction: Double? { limit.flatMap { $0 > 0 ? min(1, Double(used) / Double($0)) : nil } }
    }

    /// A command or skill the agent takes after `/` (or `$`, Codex's skills), from the machine.
    struct Command: Equatable, Sendable, Identifiable {
        let name: String
        let description: String
        var id: String { name }
    }

    /// A sub-agent the main agent started. Kept beside the conversation, never in `items`.
    struct SubagentInfo: Identifiable, Equatable, Sendable {
        enum State: String, Sendable { case running, done, failed }
        let id: String
        /// The id of the tool call that started it (where the chat shows it), if known.
        var parent: String?
        var name: String
        var kind: String
        var state: State
        var steps: Int
        var summary: String
        /// Arrival order, to keep several sub-agents of one run stable.
        var order: Int
    }

    /// The sub-agents, in the order they first appeared.
    var subagents: [SubagentInfo] { subagentMap.values.sorted { $0.order < $1.order } }
    private var subagentMap: [String: SubagentInfo] = [:]
    private var subagentCount = 0
    var runningSubagents: Int { subagentMap.values.filter { $0.state == .running }.count }

    /// What the chat shows. While the helper reads the backlog (or re-reads it after a reset),
    /// the conversation is built in `building` and shown in one step once it's caught up, so a
    /// first open lands on the finished conversation instead of growing and jumping.
    private(set) var items: [Item] = []
    /// The backlog while it is read; empty once caught up (then `items` is the one copy, mutated in place).
    @ObservationIgnored private var building: [Item] = []
    /// Where changes go: `items` once caught up, else `building`. One storage, so no per-event copy.
    private var working: [Item] {
        get { caughtUp ? items : building }
        _modify {
            if caughtUp { yield &items } else { yield &building }
        }
    }
    /// The tail of each tool's result, by the tool item's id (arrives after the tool itself).
    private(set) var toolOutput: [String: String] = [:]
    /// Assistant messages that arrived while the chat was open (not the backlog), by arrival time:
    /// their text reveals word by word.
    private(set) var revealStart: [String: Date] = [:]
    /// Items that joined while the conversation was on screen (or since it was last shown, when
    /// read again), and when: the chat fades those in. Set before they're shown, so the very
    /// first frame of a new row already knows it is new.
    private(set) var arrivedAt: [String: Date] = [:]

    /// More about a question card than its title and options (Claude's AskUserQuestion): option
    /// descriptions, that it's answered in the terminal by number, its place among the questions
    /// asked together, and the answer once given.
    struct QuestionInfo: Equatable {
        var details: [String] = []
        var keys = false
        var group: String?
        var index = 0
        var count = 1
        var answer: String?
    }
    private(set) var questionInfo: [String: QuestionInfo] = [:]
    /// The backlog is in: items that arrive from now on are live.
    private(set) var caughtUp = false
    private(set) var usage: Usage?

    /// Puts an answer given from the chat into the conversation, where it was given.
    func recordDecision(question: String, answer: String) {
        let id = "decision-\(UUID().uuidString)"
        index[id] = working.count
        working.append(Item(id: id, kind: .decision(question: question, answer: answer)))
    }
    private(set) var commands: [Command] = []
    /// Messages waiting in the agent's queue (Claude Code), oldest first, wherever they were typed.
    private(set) var queued: [String] = []

    /// A model the agent can switch to mid-session, with its effort levels.
    struct ModelOption: Equatable, Sendable, Identifiable {
        let id: String
        let name: String
        let description: String
        let note: String?
        let efforts: [String]
        let defaultEffort: String?
    }

    private(set) var models: [ModelOption] = []
    /// A newer Claude Code is installed on the machine than this conversation runs (`/update`
    /// restarts into it): the installed version, else nil.
    private(set) var newerAgent: String?
    /// Restart was tapped: it starts the newest installed version, which the conversation only
    /// records once something new is written to it (a resumed session writes nothing until then).
    func restartedIntoNewest() {
        if let newer = newerAgent { agentVersion = newer }
        newerAgent = nil
        modelsNeedingUpdate = []
    }

    /// The models in the picker that need the newer version.
    private(set) var modelsNeedingUpdate: [String] = []
    /// The conversation being followed (Claude: its session id).
    private(set) var conversationID: String?
    /// The Claude Code version this conversation runs.
    private(set) var agentVersion: String?
    /// The effort last chosen here, for agents that don't record it (Claude).
    var chosenEffort: String?
    private(set) var phase: Phase = .loading
    private var index: [String: Int] = [:]

    private static let script: String? = Bundle.main.url(forResource: "agent-feed", withExtension: "py")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    /// Follows the conversation until cancelled, reconnecting when the line drops.
    func run(session: HostSession, agent: ChatAgent, pid: Int32, cwd: String, sessionHint: String? = nil) async {
        guard let script = Self.script else {
            phase = .failed("The chat helper is missing from the app.")
            return
        }
        // The script travels base64-encoded, so no shell quoting can break it.
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' "
            + "\(encoded) \(agent.rawValue) \(pid) \(Self.shellQuote(cwd)) \(Self.shellQuote(sessionHint ?? "-"))"
        while !Task.isCancelled {
            stalled = false
            do {
                let pipe = try await session.openExec(command)
                // The helper pings every second. A channel that died quietly (the phone or the
                // machine slept) sends nothing and never errors, so without pings for a while,
                // close it and follow the conversation again; otherwise the chat and its
                // sub-agent count freeze at the last thing heard.
                lastHeard = .now
                let watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        guard let self, !Task.isCancelled else { return }
                        if Date.now.timeIntervalSince(self.lastHeard) > Self.stallAfter {
                            self.stalled = true
                            pipe.close()
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                try await withTaskCancellationHandler {
                    try await read(pipe)
                } onCancel: {
                    pipe.close()
                }
            } catch is CancellationError where stalled && !Task.isCancelled {
                // Closed by the watchdog: reconnect below.
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                if working.isEmpty { phase = .failed(Self.describe(error)) }
            }
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// When the helper was last heard from (it pings every second).
    @ObservationIgnored private var lastHeard = Date.now
    @ObservationIgnored private var stalled = false
    static let stallAfter: TimeInterval = 15

    private func read(_ pipe: ExecPipe) async throws {
        var pings = 0
        var sawConversation = false
        // Splitting, JSON, base64 and markdown happen off the main actor; chunks are awaited one
        // at a time, so events keep their order.
        let parser = ChatChunkParser()
        for try await chunk in pipe.output {
            lastHeard = .now
            let events = await parser.feed(chunk)
            for parsed in events {
                let event = parsed.event
                let type = parsed.type
                switch type {
                case "reset":
                    sawConversation = true
                    // The transcript's file name: the conversation's id, for `claude --resume`.
                    let id = (event["session"] as? String).map {
                        $0.hasSuffix(".jsonl") ? String($0.dropLast(6)) : $0
                    }
                    // Read again into `building`; what's on screen (`items`, tool output, usage)
                    // stays until the first ping, then swaps in. The same conversation read again
                    // swaps in unchanged, so coming back to a chat doesn't flash.
                    let rereading = phase == .live && id != nil && id == conversationID
                    conversationID = id
                    caughtUp = false
                    building = []
                    index = [:]
                    revealStart = [:]
                    if !rereading {
                        toolOutput = [:]
                        subagentMap = [:]
                        usage = nil
                    }
                    phase = .live
                case "usage":
                    applyUsage(event)
                case "models":
                    models = (event["items"] as? [[String: Any]] ?? []).compactMap {
                        guard let id = $0["id"] as? String else { return nil }
                        return ModelOption(id: id, name: $0["name"] as? String ?? id,
                                           description: $0["description"] as? String ?? "",
                                           note: $0["note"] as? String, efforts: $0["efforts"] as? [String] ?? [],
                                           defaultEffort: $0["default_effort"] as? String)
                    }
                case "version":
                    agentVersion = event["running"] as? String
                    newerAgent = event["installed"] as? String
                    modelsNeedingUpdate = event["needs"] as? [String] ?? []
                case "commands":
                    commands = (event["items"] as? [[String: Any]] ?? []).compactMap {
                        guard let name = $0["name"] as? String else { return nil }
                        return Command(name: name, description: $0["description"] as? String ?? "")
                    }
                case "msg", "tool", "toolout", "plan", "image", "question":
                    apply(event, type: type, prepared: parsed)
                case "subagent":
                    applySubagent(event)
                case "queued":
                    let now = event["items"] as? [String] ?? []
                    if now != queued { queued = now }
                case "ping":
                    if !caughtUp {
                        // Read again after coming back: what's new since the chat was last on
                        // screen arrives like live messages (the agent's replies write
                        // themselves out; the list animates them in), what's unchanged stays still.
                        if !items.isEmpty {
                            let shown = Set(items.map(\.id))
                            for item in building where !shown.contains(item.id) {
                                arrivedAt[item.id] = .now
                                if case .assistant = item.kind { markReveal(item.id) }
                            }
                        }
                        caughtUp = true
                        items = building
                        building = []
                    }
                    pings += 1
                    if !sawConversation && pings >= 2 { phase = .noConversation }
                case "error":
                    phase = .failed(event["text"] as? String ?? "The chat helper failed.")
                default:
                    break
                }
            }
        }
    }

    /// A reveal lasts about 1.5 s, so entries older than this are finished: drop them.
    private static let revealKeep: TimeInterval = 5

    private func markReveal(_ id: String) {
        let stale = revealStart.filter { $0.value.timeIntervalSinceNow < -Self.revealKeep }.keys
        for key in stale { revealStart[key] = nil }
        revealStart[id] = .now
    }

    /// The demo agent is answering: the chat shows it working.
    var demoWorking = false

    /// Ready-made items, for the design preview and tests.
    func loadItems(_ items: [Item]) {
        self.items = items
        building = []
        index = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        phase = .live
        caughtUp = true
    }

    /// One event, as if the helper had sent it (the demo chat).
    func applyDemo(_ event: [String: Any]) {
        switch event["t"] as? String {
        case "usage": applyUsage(event)
        case "subagent": applySubagent(event)
        case let type?: apply(event, type: type)
        default: break
        }
    }

    /// More events on top of what is there (the preview's live updates).
    func loadEvents(_ events: [[String: Any]], keepItems: Bool, extra: [[String: Any]]) {
        for event in extra where event["t"] as? String == "usage" { applyUsage(event) }
    }

    /// Sample events, for the design preview.
    func loadEvents(_ events: [[String: Any]]) {
        working = []
        index = [:]
        for event in events {
            if event["t"] as? String == "usage" { applyUsage(event) } else { apply(event, type: event["t"] as? String ?? "") }
        }
        // All in at once, like the helper's first ping.
        if !caughtUp {
            caughtUp = true
            items = building
            building = []
        }
        phase = .live
    }

    /// Upserts a sub-agent's status (by id) in the side map.
    func applySubagent(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return }
        let old = subagentMap[id]
        let next = SubagentInfo(
            id: id, parent: event["parent"] as? String ?? old?.parent,
            name: event["name"] as? String ?? old?.name ?? "Sub-agent", kind: event["kind"] as? String ?? "",
            state: SubagentInfo.State(rawValue: event["state"] as? String ?? "") ?? .running,
            steps: (event["steps"] as? NSNumber)?.intValue ?? 0, summary: event["summary"] as? String ?? "",
            order: old?.order ?? subagentCount)
        if old == nil { subagentCount += 1 }
        if next != old { subagentMap[id] = next }
    }

    private func applyUsage(_ event: [String: Any]) {
        func window(_ value: Any?) -> Usage.Window? {
            guard let w = value as? [String: Any], let percent = (w["percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return Usage.Window(percent: percent,
                    resetsAt: (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) })
        }
        let next = Usage(
            model: event["model"] as? String, effort: event["effort"] as? String, mode: event["mode"] as? String,
            used: (event["used"] as? NSNumber)?.intValue ?? 0, limit: (event["limit"] as? NSNumber)?.intValue,
            session: window(event["session"]), weekly: window(event["weekly"]))
        if next != usage { usage = next }
    }

    private func apply(_ event: [String: Any], type: String, prepared: ChatEvent? = nil) {
        guard let id = event["id"] as? String else { return }
        if type == "toolout" {
            if let text = event["text"] as? String, toolOutput[id] != text { toolOutput[id] = text }
            return
        }
        let kind: Kind
        if type == "plan" {
            let steps = (event["steps"] as? [[String: Any]] ?? []).compactMap { step -> PlanStep? in
                guard let text = step["text"] as? String else { return nil }
                return PlanStep(text: text, status: step["status"] as? String ?? "pending")
            }
            // The latest plan replaces the old one and sits at the end, where the agent is now.
            if let at = index[id] {
                working.remove(at: at)
                index = Dictionary(uniqueKeysWithValues: working.enumerated().map { ($1.id, $0) })
            }
            index[id] = working.count
            working.append(Item(id: id, kind: .plan(steps)))
            return
        } else if type == "image" {
            let fromUser = event["role"] as? String == "user"
            if let b64 = event["data"] as? String {
                guard let data = prepared?.imageData ?? Data(base64Encoded: b64) else { return }
                kind = .image(data: data, fromUser: fromUser)
            } else {
                kind = .imageLoading(width: (event["width"] as? NSNumber)?.doubleValue,
                                     height: (event["height"] as? NSNumber)?.doubleValue, fromUser: fromUser)
            }
        } else if type == "question" {
            kind = .question(title: event["title"] as? String ?? "", options: event["options"] as? [String] ?? [])
            if event["keys"] as? Bool == true || event["answer"] != nil {
                var info = questionInfo[id] ?? QuestionInfo()
                if let d = event["details"] as? [String] { info.details = d }
                if let k = event["keys"] as? Bool { info.keys = k }
                if let g = event["group"] as? String { info.group = g }
                if let i = event["index"] as? Int { info.index = i }
                if let c = event["count"] as? Int { info.count = c }
                if let a = event["answer"] as? String { info.answer = a }
                if questionInfo[id] != info { questionInfo[id] = info }
            }
        } else if type == "tool" {
            kind = .tool(name: event["name"] as? String ?? "tool", summary: event["summary"] as? String ?? "")
        } else {
            let text = event["text"] as? String ?? ""
            if event["role"] as? String == "user" {
                kind = .user(text)
            } else if event["role"] as? String == "note" {
                kind = .note(text)
            } else {
                // Unchanged text (a step read again): keep the parsed blocks.
                if let at = index[id], case .assistant(let old, _) = working[at].kind, old == text { return }
                kind = .assistant(text: text, blocks: prepared?.blocks ?? MarkdownBlock.parse(text))
            }
        }
        if let at = index[id] {
            if working[at].kind != kind { working[at].kind = kind }
        } else {
            index[id] = working.count
            if caughtUp {
                arrivedAt[id] = .now
                if arrivedAt.count > 300 { arrivedAt = arrivedAt.filter { $0.value.timeIntervalSinceNow > -5 } }
            }
            working.append(Item(id: id, kind: kind))
            if caughtUp, case .assistant = kind { markReveal(id) }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func describe(_ error: Error) -> String {
        if case SSHTransportError.commandFailed(_, let stderr) = error, !stderr.isEmpty {
            return stderr.contains("python3") ? "This machine needs python3 for the chat view. Install it there, or use the terminal view." : stderr
        }
        return error.localizedDescription
    }
}

/// One line from the helper, decoded off the main actor. The dictionary comes straight from
/// `JSONSerialization` and is never mutated, so it is safe to hand across.
nonisolated struct ChatEvent: @unchecked Sendable {
    let event: [String: Any]
    let type: String
    /// An assistant reply's parsed markdown.
    var blocks: [MarkdownBlock]?
    /// An image's decoded bytes.
    var imageData: Data?

    /// Decodes one line; nil when it isn't a JSON object with a type (or an image's data isn't base64).
    static func parse(line: Data) -> ChatEvent? {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["t"] as? String else { return nil }
        var parsed = ChatEvent(event: event, type: type)
        switch type {
        case "image":
            if let b64 = event["data"] as? String {
                guard let data = Data(base64Encoded: b64) else { return nil }
                parsed.imageData = data
            }
        case "msg":
            let role = event["role"] as? String
            if role != "user" && role != "note" {
                parsed.blocks = MarkdownBlock.parse(event["text"] as? String ?? "")
            }
        default:
            break
        }
        return parsed
    }
}

/// Splits the helper's byte stream into lines, scanning each byte once.
nonisolated struct ChatLineSplitter {
    private var pending = Data()
    /// How far into `pending` has been scanned for a newline.
    private var scanned = 0

    /// Appends a chunk and returns the complete lines it finished.
    mutating func feed(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var lineStart = 0
        let count = pending.count
        pending.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var i = scanned
            while i < count {
                if bytes[i] == 0x0A {
                    lines.append(Data(bytes[lineStart..<i]))
                    lineStart = i + 1
                }
                i += 1
            }
        }
        if lineStart > 0 { pending = Data(pending[(pending.startIndex + lineStart)...]) }
        scanned = pending.count
        return lines
    }
}

/// Parses chunks on a background executor, keeping the partial line between them.
actor ChatChunkParser {
    private var splitter = ChatLineSplitter()

    func feed(_ chunk: Data) -> [ChatEvent] {
        splitter.feed(chunk).compactMap { ChatEvent.parse(line: $0) }
    }
}
