import Foundation

/// One message on an event channel (see herdr-core `schema/README.md`, "Events").
public enum EventMessage: Sendable {
    case event(TerminalEvent)
    /// Every 15 s when nothing else happened.
    case heartbeat(seq: UInt64)
    /// We fell behind: replace everything with this snapshot.
    case missed(seq: UInt64, terminals: [Terminal])
}

public struct TerminalEvent: Sendable {
    public let seq: UInt64
    /// `t7` or `machine/t7`; nil for document events.
    public let terminal: String?
    public let change: Change

    public enum Change: Sendable {
        case created(Terminal)
        case restarted(Terminal)
        case removed
        case finished(reason: String?, exitCode: Int32?)
        /// A kept terminal lost its program; it stays live and waits for a new shell.
        case lost(reason: String?, exitCode: Int32?)
        case status(TerminalStatus?)
        case title(String)
        /// All labels now; `record` when the terminal newly matches the subscription's filter.
        case labels([String: String], record: Terminal?)
        case size(cols: Int, rows: Int)
        case foreground(Foreground?)
        case doc(name: String)
        /// A turn ended: the status left `working`.
        case turn(UInt64)
        /// Kinds we do not model (`keep`, newer ones).
        case other(type: String)
    }
}

extension EventMessage {
    /// Decodes one JSON line from an event channel; nil for anything unrecognised.
    static func decode(_ line: Data) -> EventMessage? {
        let decoder = JSONDecoder()
        guard let head = try? decoder.decode(Head.self, from: line) else { return nil }
        switch head.method {
        case "heartbeat":
            return head.params.seq.map { .heartbeat(seq: $0) }
        case "missed":
            guard let missed = try? decoder.decode(Notification<Missed>.self, from: line) else { return nil }
            return .missed(seq: missed.params.seq, terminals: missed.params.terminals ?? [])
        case "event":
            guard let event = try? decoder.decode(Notification<RawEvent>.self, from: line) else { return nil }
            return .event(event.params.event)
        default:
            return nil
        }
    }

    private struct Head: Decodable {
        struct Params: Decodable { let seq: UInt64? }
        let method: String
        let params: Params
    }

    private struct Notification<Params: Decodable>: Decodable {
        let params: Params
    }

    private struct Missed: Decodable {
        let seq: UInt64
        let terminals: [Terminal]?
    }

    private struct RawEvent: Decodable {
        let event: TerminalEvent

        enum CodingKeys: String, CodingKey { case seq, type, terminal, data }

        struct Ended: Decodable {
            let reason: String?
            let exitCode: Int32?
            enum CodingKeys: String, CodingKey {
                case reason
                case exitCode = "exit_code"
            }
        }
        struct Status: Decodable { let status: TerminalStatus? }
        struct Title: Decodable { let title: String }
        struct Labels: Decodable {
            let labels: [String: String]?
            let record: Terminal?
        }
        struct Size: Decodable {
            let cols: Int
            let rows: Int
        }
        struct Doc: Decodable { let name: String }
        struct Turn: Decodable { let turn: UInt64 }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            let change: TerminalEvent.Change
            switch type {
            case "created": change = .created(try c.decode(Terminal.self, forKey: .data))
            case "restarted": change = .restarted(try c.decode(Terminal.self, forKey: .data))
            case "removed": change = .removed
            case "finished":
                let ended = try c.decode(Ended.self, forKey: .data)
                change = .finished(reason: ended.reason, exitCode: ended.exitCode)
            case "lost":
                let ended = try c.decode(Ended.self, forKey: .data)
                change = .lost(reason: ended.reason, exitCode: ended.exitCode)
            case "status": change = .status(try c.decode(Status.self, forKey: .data).status)
            case "title": change = .title(try c.decode(Title.self, forKey: .data).title)
            case "labels":
                let labels = try c.decode(Labels.self, forKey: .data)
                change = .labels(labels.labels ?? [:], record: labels.record)
            case "size":
                let size = try c.decode(Size.self, forKey: .data)
                change = .size(cols: size.cols, rows: size.rows)
            case "foreground": change = .foreground(try c.decodeIfPresent(Foreground.self, forKey: .data))
            case "doc": change = .doc(name: try c.decode(Doc.self, forKey: .data).name)
            case "turn": change = .turn(try c.decode(Turn.self, forKey: .data).turn)
            default: change = .other(type: type)
            }
            event = TerminalEvent(
                seq: try c.decode(UInt64.self, forKey: .seq),
                terminal: try c.decodeIfPresent(String.self, forKey: .terminal),
                change: change)
        }
    }
}

/// Terminals as last seen, kept current by applying events in order.
public struct TerminalSnapshot: Sendable {
    public private(set) var seq: UInt64
    public private(set) var terminals: [Terminal]

    public init(seq: UInt64, terminals: [Terminal]) {
        self.seq = seq
        self.terminals = terminals
    }

    public subscript(address: String) -> Terminal? {
        terminals.first { $0.address == address }
    }

    /// Applies one message. Returns false when it was stale and ignored.
    @discardableResult
    public mutating func apply(_ message: EventMessage) -> Bool {
        switch message {
        case .heartbeat:
            return true
        case .missed(let seq, let terminals):
            self.seq = seq
            self.terminals = terminals
            return true
        case .event(let event):
            // After a `missed` snapshot, events up to its seq are already in it.
            guard event.seq > seq else { return false }
            seq = event.seq
            if let address = event.terminal { apply(event.change, to: address) }
            return true
        }
    }

    private mutating func apply(_ change: TerminalEvent.Change, to address: String) {
        let index = terminals.firstIndex { $0.address == address }
        switch change {
        case .created(let terminal), .restarted(let terminal):
            if let index { terminals[index] = terminal } else { terminals.append(terminal) }
        case .removed:
            if let index { terminals.remove(at: index) }
        case .labels(let labels, let record):
            if let index {
                terminals[index].labels = labels
            } else if let record {
                terminals.append(record)
            }
        default:
            guard let index else { return }
            update(&terminals[index], with: change)
        }
    }

    private func update(_ terminal: inout Terminal, with change: TerminalEvent.Change) {
        switch change {
        case .finished(let reason, let exitCode):
            terminal.state = "finished"
            terminal.reason = reason
            terminal.exitCode = exitCode
            terminal.foreground = nil
        case .lost(let reason, let exitCode):
            terminal.reason = reason
            terminal.exitCode = exitCode
            terminal.foreground = nil
        case .status(let status): terminal.status = status
        case .title(let title): terminal.title = title
        case .size(let cols, let rows):
            terminal.cols = cols
            terminal.rows = rows
        case .foreground(let foreground): terminal.foreground = foreground
        case .turn(let turn): terminal.turn = turn
        case .created, .restarted, .removed, .labels, .doc, .other: break
        }
    }
}
