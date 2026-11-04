import Foundation

/// What to start in a new terminal (`terminal.run`).
public struct RunRequest: Encodable, Sendable {
    /// Program and arguments, or a template name followed by its task. With neither
    /// `argv` nor `line`, the machine's own shell.
    public var argv: [String]?
    /// A shell line, run by the machine's shell (`sh -c`).
    public var line: String?
    public var cwd: String?
    public var name: String?
    public var labels: [String: String]?
    /// Replace a lost program with a fresh shell in place (never re-runs the command).
    public var keep: Bool?
    public var env: [String: String]?
    /// Another machine added on this core.
    public var on: String?

    /// The terminal identity herdr-app gives its terminals.
    public static let terminalEnvironment = ["TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "herdr"]

    public init(
        argv: [String]? = nil, line: String? = nil, cwd: String? = nil, name: String? = nil,
        labels: [String: String]? = nil, keep: Bool? = nil, env: [String: String]? = Self.terminalEnvironment,
        on: String? = nil
    ) {
        self.argv = argv
        self.line = line
        self.cwd = cwd
        self.name = name
        self.labels = labels
        self.keep = keep
        self.env = env
        self.on = on
    }
}

/// An agent role saved as `~/.config/herdr-core/templates/<name>.md` on the machine.
public struct TemplateInfo: Decodable, Hashable, Sendable, Identifiable {
    public let name: String
    public let description: String
    public let command: String
    /// Set when the file can't be used.
    public let error: String?
    public var id: String { name }
}

extension HerdrCore {
    /// herdr-core's rule (`addr.rs` `check_name`): 1–32 of a-z 0-9 - _ . starting with a
    /// letter or digit, and not shaped like an address such as `t7`.
    public static func isValidTerminalName(_ name: String) -> Bool {
        guard (1...32).contains(name.count),
              let first = name.unicodeScalars.first, isLowerOrDigit(first),
              name.unicodeScalars.allSatisfy({ isLowerOrDigit($0) || "-_.".unicodeScalars.contains($0) })
        else { return false }
        return !isIDShaped(name)
    }

    private static func isLowerOrDigit(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("0"..."9").contains(c)
    }

    /// `t` + a digit 1–9 + herdr's id alphabet: these names are taken by addresses.
    private static func isIDShaped(_ name: String) -> Bool {
        guard name.hasPrefix("t") else { return false }
        let rest = name.dropFirst()
        guard let first = rest.first, ("1"..."9").contains(first) else { return false }
        return rest.allSatisfy { "0123456789bcdfghjkmnpqrstvwxyz".contains($0) }
    }
}

extension HerdrClient {
    /// Starts a terminal; returns once it runs (for a template: once its first message is sent).
    public func run(_ request: RunRequest) async throws -> Terminal {
        try await call("terminal.run", request)
    }

    public func templates() async throws -> [TemplateInfo] {
        let result: TemplatesResult = try await call("templates.list", EmptyParams())
        return result.templates
    }

    /// Ends the program: hangup, then terminate, then kill.
    public func kill(_ address: String) async throws {
        let _: JSONValue = try await call("terminal.kill", TerminalParam(terminal: address))
    }

    /// Sets labels; an empty value removes that label.
    public func label(_ address: String, _ labels: [String: String]) async throws {
        let _: JSONValue = try await call("terminal.label", LabelParams(terminal: address, labels: labels))
    }

    /// Removes a finished terminal from the list.
    public func remove(_ address: String) async throws {
        let _: JSONValue = try await call("terminal.rm", TerminalParam(terminal: address))
    }
}

struct TemplatesResult: Decodable, Sendable {
    let templates: [TemplateInfo]
}

struct LabelParams: Encodable, Sendable {
    let terminal: String
    let labels: [String: String]
}

struct TerminalParam: Encodable, Sendable {
    let terminal: String
}
