import Foundation

// Types from herdr-core's `schema/hc.openrpc.json` (protocol generation 1).
// Only the fields the app uses; unknown fields are ignored, so newer cores keep working.

public struct CoreInfo: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
}

public struct HelloResult: Decodable, Sendable {
    public let generation: Int
    public let version: String
    public let core: CoreInfo
    public let framed: Bool
    public let methods: [String]
    public let features: [String]
}

/// One OSC 7501 status record, as the program reported it.
public struct TerminalStatus: Codable, Hashable, Sendable {
    /// idle, working, done, blocked or error.
    public let state: String
    public let app: String?
    public let title: String?
    public let msg: String?
    /// permission, question or auth (blocked only).
    public let kind: String?
    public let progress: Int?
}

public struct Foreground: Codable, Hashable, Sendable {
    public let pid: Int32
    public let name: String
    public let argv: [String]
    public let cwd: String
}

public struct Terminal: Codable, Hashable, Sendable, Identifiable {
    /// `t7`, or `machine/t7` for one on a machine this core added.
    public let address: String
    public internal(set) var name: String?
    public internal(set) var argv: [String]
    public internal(set) var cwd: String
    /// live or finished.
    public internal(set) var state: String
    public internal(set) var title: String?
    public internal(set) var status: TerminalStatus?
    public internal(set) var foreground: Foreground?
    public internal(set) var labels: [String: String]
    public internal(set) var cols: Int
    public internal(set) var rows: Int
    public internal(set) var createdMs: UInt64
    public internal(set) var exitCode: Int32?
    public internal(set) var reason: String?
    public internal(set) var parent: String?
    /// core's counter: up by one each time the status leaves `working`. Nil from a core that
    /// doesn't send it.
    public internal(set) var turn: UInt64?
    /// When the status word last changed (ms since the epoch, the machine's clock); nil if it
    /// never said.
    public internal(set) var statusMs: UInt64?

    public var id: String { address }

    public var isLive: Bool { state == "live" }

    /// The best short name: given name, herdr-app's location label, title, or address.
    public var displayName: String {
        if let name, !name.isEmpty { return name }
        if let place = labels["where"], !place.isEmpty { return place }
        if let title, !title.isEmpty { return title }
        return address
    }

    enum CodingKeys: String, CodingKey {
        case address, name, argv, cwd, state, title, status, foreground, labels, cols, rows, reason, parent, turn
        case createdMs = "created_ms"
        case exitCode = "exit_code"
        case statusMs = "status_ms"
    }

    public init(from decoder: Decoder) throws {
        // herdr-core (0.1.16) may omit fields its schema calls required (`skip_serializing_if`).
        // Only the address is essential; everything else falls back to empty.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decode(String.self, forKey: .address)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        argv = try c.decodeIfPresent([String].self, forKey: .argv) ?? []
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "live"
        title = try c.decodeIfPresent(String.self, forKey: .title)
        status = try c.decodeIfPresent(TerminalStatus.self, forKey: .status)
        foreground = try c.decodeIfPresent(Foreground.self, forKey: .foreground)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
        cols = try c.decodeIfPresent(Int.self, forKey: .cols) ?? 0
        rows = try c.decodeIfPresent(Int.self, forKey: .rows) ?? 0
        createdMs = try c.decodeIfPresent(UInt64.self, forKey: .createdMs) ?? 0
        exitCode = try c.decodeIfPresent(Int32.self, forKey: .exitCode)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        turn = try c.decodeIfPresent(UInt64.self, forKey: .turn)
        statusMs = try c.decodeIfPresent(UInt64.self, forKey: .statusMs)
    }
}

public struct MachineView: Codable, Hashable, Sendable, Identifiable {
    /// What this core calls it: `rohan` in `rohan/t7`.
    public let name: String
    public let host: String?
    /// connecting, connected, needs_login or unreachable.
    public let state: String
    public let target: String?
    public let version: String?

    public var id: String { name }
}

public struct TerminalList: Codable, Sendable {
    public let terminals: [Terminal]
    public let hiddenFinished: Int
    public let machines: [MachineView]

    enum CodingKeys: String, CodingKey {
        case terminals, machines
        case hiddenFinished = "hidden_finished"
    }

    public init(from decoder: Decoder) throws {
        // herdr-core (0.1.16) omits an empty `machines` although its
        // schema requires it. Decode missing lists as empty.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminals = try c.decodeIfPresent([Terminal].self, forKey: .terminals) ?? []
        hiddenFinished = try c.decodeIfPresent(Int.self, forKey: .hiddenFinished) ?? 0
        machines = try c.decodeIfPresent([MachineView].self, forKey: .machines) ?? []
    }
}
