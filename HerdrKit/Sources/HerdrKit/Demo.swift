import Foundation

/// A pretend herdr-core inside the app, for the demo machine: App Review and first-time
/// users can try everything without a server. It speaks the real protocol (hello, framed
/// mode, events, attach), so the app uses it exactly like `herdr-core connect` over SSH.
public final class DemoCore: ByteTransport {
    public let incoming: AsyncThrowingStream<Data, Error>
    private let engine: DemoEngine

    public init() {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        incoming = stream
        engine = DemoEngine(output: continuation)
    }

    public func send(_ data: Data) async throws {
        await engine.receive(data)
    }

    public func close() {
        Task { [engine] in await engine.shutdown() }
    }
}

extension HerdrClient {
    /// Connects to an in-app `DemoCore`.
    public static func connectDemo() async throws -> HerdrClient {
        try await connect(over: DemoCore())
    }
}

// MARK: - Engine

private actor DemoEngine {
    private let output: AsyncThrowingStream<Data, Error>.Continuation
    private var reader = FrameReader()
    private var framed = false
    private var closed = false

    private var terminals = DemoScript.terminals()
    private var roles = DemoScript.roles
    private var seq: UInt64 = 100
    private var nextChannel: UInt32 = 1
    private var nextTerminal = 8

    private var eventChannels: Set<UInt32> = []
    private var views: [UInt32: View] = [:]
    private var tasks: [UInt32: Task<Void, Never>] = [:]
    private var clock: Task<Void, Never>?

    /// One attached viewer.
    private struct View {
        let address: String
        /// Watches only, like herdr-core's `observe`: its typing and size don't count.
        var observe = false
        var line = ""
    }

    init(output: AsyncThrowingStream<Data, Error>.Continuation) {
        self.output = output
    }

    func shutdown() {
        closed = true
        clock?.cancel()
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        output.finish()
    }

    // MARK: Input

    func receive(_ data: Data) {
        guard !closed else { return }
        reader.append(data)
        while true {
            if !framed {
                guard let line = reader.nextLine() else { return }
                if !line.isEmpty { handle(message: line) }
            } else {
                guard let frame = try? reader.nextFrame() else { return }
                handle(frame: frame)
            }
        }
    }

    private func handle(frame: Frame) {
        if frame.channel == 0 {
            if frame.kind == Frame.Kind.data.rawValue { handle(message: frame.payload) }
            return
        }
        switch Frame.Kind(rawValue: frame.kind) {
        case .data:
            guard views[frame.channel]?.observe != true else { return }
            typed(frame.payload, on: frame.channel)
        case .close:
            eventChannels.remove(frame.channel)
            views.removeValue(forKey: frame.channel)
            tasks.removeValue(forKey: frame.channel)?.cancel()
        case .resize:
            guard frame.payload.count >= 4, let view = views[frame.channel], !view.observe else { return }
            let bytes = [UInt8](frame.payload)
            let cols = Int(bytes[0]) | Int(bytes[1]) << 8
            let rows = Int(bytes[2]) | Int(bytes[3]) << 8
            resize(view.address, cols: cols, rows: rows)
        default:
            break // credit, focus, facts: nothing to do here
        }
    }

    private func handle(message: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any],
              let method = object["method"] as? String else { return }
        let id = object["id"] as? Int
        let params = object["params"] as? [String: Any] ?? [:]
        do {
            let (result, after) = try answer(method, params)
            if let id { reply(id: id, result: result) }
            if method == "hello" { framed = true }
            after?()
        } catch let error as DemoError {
            if let id { reply(id: id, error: error) }
        } catch {
            if let id { reply(id: id, error: DemoError(code: -32603, message: "\(error)", kind: nil)) }
        }
    }

    // MARK: Methods

    /// The result, and work to do once it is sent (stream data must follow its reply).
    private func answer(_ method: String, _ params: [String: Any]) throws -> (Data, (() -> Void)?) {
        switch method {
        case "hello":
            return (try encode(Hello()), nil)

        case "terminal.list":
            return (try encode(ListResult(terminals: terminals)), nil)

        case "doc.get":
            let name = params["name"] as? String
            let value = name == HerdrAppLayout.documentName ? DemoScript.layout : "null"
            let version = name == HerdrAppLayout.documentName ? 1 : 0
            return (Data(#"{"value":\#(value),"version":\#(version)}"#.utf8), nil)

        case "events.subscribe":
            let channel = openChannel()
            eventChannels.insert(channel)
            startClock()
            return (try encode(Subscribed(seq: seq, terminals: terminals, channel: channel)), nil)

        case "terminal.attach":
            let address = params["terminal"] as? String ?? ""
            guard let index = terminals.firstIndex(where: { $0.address == address }) else {
                throw DemoError.notFound(address)
            }
            guard terminals[index].state == "live" else {
                throw DemoError(code: -32000, message: "\(address) has finished", kind: "finished")
            }
            let cols = max(params["cols"] as? Int ?? 80, 20), rows = max(params["rows"] as? Int ?? 24, 5)
            let observe = params["observe"] as? Bool ?? false
            if !observe { resize(address, cols: cols, rows: rows) }
            let channel = openChannel()
            views[channel] = View(address: address, observe: observe)
            let result = try encode(Attached(channel: channel, terminal: terminals[index]))
            return (result, { [weak self] in
                Task { await self?.paint(channel) }
            })

        case "terminal.run":
            return (try encode(run(params)), nil)

        case "templates.list":
            return (Data(DemoScript.templates.utf8), nil)

        case "terminal.kill":
            let address = params["terminal"] as? String ?? ""
            try finish(address, reason: "killed", exitCode: nil)
            return (Data("null".utf8), nil)

        case "terminal.rm":
            let address = params["terminal"] as? String ?? ""
            guard let index = terminals.firstIndex(where: { $0.address == address }) else { throw DemoError.notFound(address) }
            terminals.remove(at: index)
            emit("removed", address, data: "null")
            return (Data("null".utf8), nil)

        case "terminal.label":
            let address = params["terminal"] as? String ?? ""
            guard let index = terminals.firstIndex(where: { $0.address == address }) else { throw DemoError.notFound(address) }
            for (key, value) in params["labels"] as? [String: String] ?? [:] {
                terminals[index].labels[key] = value.isEmpty ? nil : value
            }
            emit("labels", address, data: try json(["labels": terminals[index].labels]))
            return (Data("null".utf8), nil)

        default:
            throw DemoError(code: -32601, message: "The demo machine does not do \(method).", kind: "unknown_method")
        }
    }

    private func run(_ params: [String: Any]) throws -> DemoTerminal {
        let name = params["name"] as? String
        if let name, !HerdrCore.isValidTerminalName(name) {
            throw DemoError(code: -32602, message: "\(name) is not a valid terminal name", kind: "invalid_name")
        }
        if let name, terminals.contains(where: { $0.name == name && $0.state == "live" }) {
            throw DemoError(code: -32000, message: "a terminal named \(name) already runs", kind: "name_taken")
        }
        let address = "t\(nextTerminal)"
        nextTerminal += 1
        let cwd = params["cwd"] as? String ?? DemoScript.home
        var terminal = DemoTerminal(
            address: address, name: name, argv: ["zsh"], cwd: cwd,
            labels: params["labels"] as? [String: String] ?? [:],
            foreground: .init(pid: Int32(40_000 + nextTerminal), name: "zsh", argv: ["zsh"], cwd: cwd),
            createdMs: DemoScript.now)
        if let argv = params["argv"] as? [String], let first = argv.first {
            // A template or command: show it as a fresh agent that waits for its first turn.
            terminal.argv = argv
            terminal.status = .init(state: "idle", app: "agent", title: first, msg: argv.dropFirst().joined(separator: " "))
            terminal.foreground = nil
            roles[address] = .agent(DemoScript.newAgentPaint(task: argv.dropFirst().joined(separator: " ")))
        } else {
            roles[address] = .shell(history: "", cwd: cwd)
        }
        terminals.append(terminal)
        emit("created", address, data: try json(terminal))
        return terminal
    }

    private func finish(_ address: String, reason: String?, exitCode: Int32?) throws {
        guard let index = terminals.firstIndex(where: { $0.address == address }) else { throw DemoError.notFound(address) }
        guard terminals[index].state == "live" else { return }
        terminals[index].state = "finished"
        terminals[index].reason = reason
        terminals[index].exitCode = exitCode
        terminals[index].foreground = nil
        emit("finished", address, data: try json(Ended(reason: reason, exitCode: exitCode)))
        // Viewers see the end of the stream.
        let end = (try? json(Ended(reason: reason ?? "exited", exitCode: exitCode))) ?? "{}"
        for (channel, view) in views where view.address == address {
            send(Frame(channel: channel, kind: .close, payload: Data(end.utf8)))
            views.removeValue(forKey: channel)
            tasks.removeValue(forKey: channel)?.cancel()
        }
    }

    private func resize(_ address: String, cols: Int, rows: Int) {
        guard let index = terminals.firstIndex(where: { $0.address == address }),
              terminals[index].cols != cols || terminals[index].rows != rows else { return }
        terminals[index].cols = cols
        terminals[index].rows = rows
        emit("size", address, data: #"{"cols":\#(cols),"rows":\#(rows)}"#)
    }

    private func setStatus(_ address: String, _ status: DemoStatus?) {
        guard let index = terminals.firstIndex(where: { $0.address == address }),
              terminals[index].state == "live" else { return }
        terminals[index].status = status
        let body = (try? status.map { try json($0) }) ?? nil
        emit("status", address, data: #"{"status":\#(body ?? "null")}"#)
    }

    // MARK: Screens

    private func paint(_ channel: UInt32) {
        guard let view = views[channel], let role = roles[view.address] else { return }
        write(channel, DemoScript.clear + role.paint)
        if case .stream(_, let lines, let interval) = role {
            tasks[channel] = Task { [weak self] in
                var index = 0
                while !Task.isCancelled, !lines.isEmpty {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await self?.write(channel, lines[index % lines.count])
                    index += 1
                }
            }
        }
    }

    /// What a viewer typed.
    private func typed(_ data: Data, on channel: UInt32) {
        guard var view = views[channel], let role = roles[view.address] else { return }
        let text = String(decoding: data, as: UTF8.self)
        switch role {
        case .stream:
            if text.contains("\u{03}") { write(channel, "^C\r\n" + DemoScript.dim("(this demo keeps running)") + "\r\n") }
            return
        case .approval:
            approve(view.address, yes: text.lowercased().hasPrefix("y"), channel: channel)
            return
        case .shell, .agent:
            break
        }
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r", "\n":
                let line = view.line
                view.line = ""
                views[channel] = view
                write(channel, "\r\n")
                submit(line, role: role, channel: channel, address: view.address)
            case "\u{7f}", "\u{08}":
                if !view.line.isEmpty {
                    view.line.removeLast()
                    write(channel, "\u{08} \u{08}")
                }
            case "\u{03}":
                view.line = ""
                write(channel, "^C\r\n" + role.prompt)
            case "\u{0c}":
                write(channel, DemoScript.clear + role.prompt + view.line)
            default:
                // Printable text; escape sequences (arrows, ...) are ignored.
                if scalar.value >= 0x20, scalar != "\u{1b}", !text.hasPrefix("\u{1b}") {
                    view.line.unicodeScalars.append(scalar)
                    write(channel, String(scalar))
                }
            }
        }
        views[channel] = view
    }

    private func submit(_ line: String, role: DemoScript.Role, channel: UInt32, address: String) {
        switch role {
        case .shell:
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "exit" {
                try? finish(address, reason: "exited", exitCode: 0)
                return
            }
            if trimmed == "clear" {
                write(channel, DemoScript.clear + role.prompt)
                return
            }
            let cwd = terminals.first { $0.address == address }?.cwd ?? DemoScript.home
            write(channel, DemoScript.shell(trimmed, cwd: cwd) + role.prompt)
        case .agent:
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                write(channel, role.prompt)
                return
            }
            write(channel, DemoScript.agentReply + role.prompt)
        case .stream, .approval:
            break
        }
    }

    /// The blocked agent: yes lets it finish its work, no stops it.
    private func approve(_ address: String, yes: Bool, channel: UInt32) {
        roles[address] = .agent(DemoScript.approvalPaint + (yes ? DemoScript.approved : DemoScript.denied))
        write(channel, yes ? DemoScript.approved : DemoScript.denied)
        guard yes else {
            setStatus(address, .init(state: "idle", app: "agent", title: "Migration skipped", msg: nil))
            write(channel, DemoScript.Role.agent("").prompt)
            return
        }
        setStatus(address, .init(state: "working", app: "agent", title: "Running the migration", msg: nil, progress: 40))
        tasks[channel]?.cancel()
        tasks[channel] = Task { [weak self] in
            for line in DemoScript.migrationOutput {
                try? await Task.sleep(for: .milliseconds(700))
                await self?.write(channel, line)
            }
            await self?.setStatus(address, .init(state: "done", app: "agent", title: "Migration applied", msg: "orders.total_cents added"))
            await self?.write(channel, DemoScript.migrationDone + DemoScript.Role.agent("").prompt)
            await self?.becomeAgent(address, paint: DemoScript.approvalPaint + DemoScript.approved
                + DemoScript.migrationOutput.joined() + DemoScript.migrationDone)
        }
    }

    private func becomeAgent(_ address: String, paint: String) {
        roles[address] = .agent(paint)
    }

    // MARK: Events

    /// Things happen on their own, so the list is alive: tests finish, an agent works on.
    private func startClock() {
        guard clock == nil else { return }
        clock = Task { [weak self] in
            var elapsed: Duration = .zero
            var steps = DemoScript.timeline
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                elapsed += .seconds(1)
                while let step = steps.first, step.at <= elapsed {
                    steps.removeFirst()
                    await self?.setStatus(step.address, step.status)
                }
                if elapsed.components.seconds % 15 == 0 { await self?.heartbeat() }
            }
        }
    }

    private func heartbeat() {
        let line = #"{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":\#(seq)}}"# + "\n"
        for channel in eventChannels { send(Frame(channel: channel, kind: .data, payload: Data(line.utf8))) }
    }

    private func emit(_ type: String, _ address: String?, data: String) {
        seq += 1
        let terminal = address.map { #""\#($0)""# } ?? "null"
        let line = #"{"jsonrpc":"2.0","method":"event","params":{"seq":\#(seq),"type":"\#(type)","terminal":\#(terminal),"data":\#(data)}}"# + "\n"
        for channel in eventChannels { send(Frame(channel: channel, kind: .data, payload: Data(line.utf8))) }
    }

    // MARK: Output

    private func openChannel() -> UInt32 {
        nextChannel += 1
        return nextChannel
    }

    private func write(_ channel: UInt32, _ text: String) {
        guard views[channel] != nil else { return }
        send(Frame(channel: channel, kind: .data, payload: Data(text.utf8)))
    }

    private func reply(id: Int, result: Data) {
        var message = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":"#.utf8)
        message.append(result)
        message.append(Data("}".utf8))
        sendControl(message)
    }

    private func reply(id: Int, error: DemoError) {
        let kind = error.kind.map { #","data":{"kind":"\#($0)"}"# } ?? ""
        let text = (try? json(error.message)) ?? "\"error\""
        sendControl(Data(#"{"jsonrpc":"2.0","id":\#(id),"error":{"code":\#(error.code),"message":\#(text)\#(kind)}}"#.utf8))
    }

    /// Channel 0: a plain line before the hello reply, frames after it.
    private func sendControl(_ message: Data) {
        if framed {
            send(Frame(channel: 0, kind: .data, payload: message))
        } else {
            guard !closed else { return }
            output.yield(message + Data([0x0A]))
        }
    }

    private func send(_ frame: Frame) {
        guard !closed else { return }
        output.yield(frame.encoded())
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

private struct DemoError: Error {
    let code: Int
    let message: String
    let kind: String?

    static func notFound(_ address: String) -> DemoError {
        DemoError(code: -32000, message: "no terminal \(address)", kind: "not_found")
    }
}

// MARK: - Wire records

struct DemoStatus: Encodable, Sendable {
    var state: String
    var app: String?
    var title: String?
    var msg: String?
    var kind: String?
    var progress: Int?

    init(state: String, app: String? = nil, title: String? = nil, msg: String? = nil, kind: String? = nil, progress: Int? = nil) {
        self.state = state
        self.app = app
        self.title = title
        self.msg = msg
        self.kind = kind
        self.progress = progress
    }
}

struct DemoForeground: Encodable, Sendable {
    var pid: Int32
    var name: String
    var argv: [String]
    var cwd: String
}

struct DemoTerminal: Encodable, Sendable {
    var address: String
    var name: String?
    var argv: [String]
    var cwd: String
    var state = "live"
    var title: String?
    var status: DemoStatus?
    var foreground: DemoForeground?
    var labels: [String: String] = [:]
    var cols = 80
    var rows = 24
    var createdMs: UInt64
    var exitCode: Int32?
    var reason: String?
    var parent: String?

    init(address: String, name: String? = nil, argv: [String], cwd: String, state: String = "live",
         title: String? = nil, status: DemoStatus? = nil, labels: [String: String] = [:],
         foreground: DemoForeground? = nil, createdMs: UInt64, exitCode: Int32? = nil,
         reason: String? = nil, parent: String? = nil) {
        self.address = address
        self.name = name
        self.argv = argv
        self.cwd = cwd
        self.state = state
        self.title = title
        self.status = status
        self.labels = labels
        self.foreground = foreground
        self.createdMs = createdMs
        self.exitCode = exitCode
        self.reason = reason
        self.parent = parent
    }

    enum CodingKeys: String, CodingKey {
        case address, name, argv, cwd, state, title, status, foreground, labels, cols, rows, reason, parent
        case createdMs = "created_ms"
        case exitCode = "exit_code"
    }
}

private struct Hello: Encodable {
    let generation = HerdrCore.generation
    let version = "demo"
    let core = CoreInfo(id: "demo", name: "demo")
    let framed = true
    let methods = ["hello", "terminal.list", "terminal.attach", "terminal.run", "terminal.kill", "terminal.rm",
                   "terminal.label", "events.subscribe", "doc.get", "templates.list"]
    let features: [String] = []
}

private struct ListResult: Encodable {
    let terminals: [DemoTerminal]
    let hiddenFinished = 0
    let machines: [String] = []

    enum CodingKeys: String, CodingKey {
        case terminals, machines
        case hiddenFinished = "hidden_finished"
    }
}

private struct Subscribed: Encodable {
    let seq: UInt64
    let terminals: [DemoTerminal]
    let channel: UInt32
}

private struct Attached: Encodable {
    let channel: UInt32
    let terminal: DemoTerminal
}

private struct Ended: Encodable {
    let reason: String?
    let exitCode: Int32?

    enum CodingKeys: String, CodingKey {
        case reason
        case exitCode = "exit_code"
    }
}
