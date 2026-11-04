import Foundation

/// Any JSON value, for documents whose shape belongs to someone else.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var array: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }
}

/// herdr-app's layout, as it stores it in the core (`doc.get {name: "herdr-app"}`):
/// spaces hold tabs, tabs hold a tree of panes, panes show terminals.
public struct HerdrAppLayout: Hashable, Sendable {
    public static let documentName = "herdr-app"

    public struct Space: Hashable, Sendable, Identifiable {
        public let id: String
        /// Empty when the user never named it; see `TerminalGrouping` for the fallback.
        public let name: String
        public let folder: String
        public let tabs: [Tab]
    }

    public struct Tab: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// Terminal addresses in pane order.
        public let terminals: [String]
    }

    public let spaces: [Space]

    /// Label key herdr-app reads to place a terminal: a running herdr-app adopts a live
    /// terminal labeled with a space id into that space (a new tab unless `tabLabel` is
    /// set too), and makes the space if it doesn't know the id.
    public static let spaceLabel = "herdr.space"
    public static let tabLabel = "herdr.tab"

    /// A fresh space id in herdr-app's format (`sp` + 32 hex digits): labeling a terminal
    /// with it makes herdr-app open a new space for it.
    public static func newSpaceID() -> String {
        "sp" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public init(spaces: [Space]) {
        self.spaces = spaces
    }

    /// Reads the document leniently: unknown fields are ignored, pane trees are
    /// walked for any `content.terminal`, so layout changes in herdr-app keep working.
    public init(document: JSONValue) {
        spaces = (document["spaces"]?.array ?? []).compactMap { space in
            guard let id = space["id"]?.string else { return nil }
            let tabs = (space["tabs"]?.array ?? []).compactMap { tab -> Tab? in
                guard let tabID = tab["id"]?.string else { return nil }
                var terminals: [String] = []
                Self.collectTerminals(tab["root"], into: &terminals)
                return Tab(id: tabID, name: tab["name"]?.string ?? "", terminals: terminals)
            }
            return Space(id: id, name: space["name"]?.string ?? "", folder: space["folder"]?.string ?? "", tabs: tabs)
        }
    }

    private static func collectTerminals(_ node: JSONValue?, into terminals: inout [String]) {
        guard let node else { return }
        if let address = node["content"]?["terminal"]?.string, !terminals.contains(address) {
            terminals.append(address)
        }
        for child in node["children"]?.array ?? [] { collectTerminals(child, into: &terminals) }
    }
}

/// A section of the terminal list: a herdr-app space, a remote machine, or the rest.
public struct TerminalSection: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case space(id: String)
        case machine(name: String)
        case other
    }

    public struct Row: Hashable, Sendable, Identifiable {
        public let terminal: Terminal
        /// 0 for top level; children of an agent are one deeper than it.
        public let depth: Int
        /// The tab it sits in, when its space has more than one tab.
        public let tab: String?
        public var id: String { terminal.address }
    }

    public let kind: Kind
    public let title: String
    /// The folder a space works in.
    public let subtitle: String?
    public let rows: [Row]

    public var id: String {
        switch kind {
        case .space(let id): "space:\(id)"
        case .machine(let name): "machine:\(name)"
        case .other: "other"
        }
    }

    /// Terminals in this section waiting for a person.
    public var needsYou: Int {
        rows.filter { $0.terminal.isLive && ["blocked", "error"].contains($0.terminal.status?.state ?? "") }.count
    }
}

public enum TerminalGrouping {
    /// Groups terminals the way herdr-app shows them: by space and tab, with agents'
    /// children nested under them. Terminals no space knows go by machine, then "Other".
    public static func bySpace(_ terminals: [Terminal], layout: HerdrAppLayout?) -> [TerminalSection] {
        let byAddress = Dictionary(terminals.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })
        let children = Dictionary(grouping: terminals.filter { $0.parent.map { byAddress[$0] != nil } ?? false },
                                  by: { $0.parent! })
        var placed = Set<String>()
        var sections: [TerminalSection] = []

        /// Adds a terminal and, right after it, everything it started.
        func place(_ terminal: Terminal, depth: Int, tab: String?, into rows: inout [TerminalSection.Row]) {
            guard placed.insert(terminal.address).inserted else { return }
            rows.append(.init(terminal: terminal, depth: depth, tab: tab))
            for child in (children[terminal.address] ?? []).sorted(by: { $0.createdMs < $1.createdMs }) {
                place(child, depth: depth + 1, tab: tab, into: &rows)
            }
        }

        // Children are placed with their parent, so they never start a group of their own.
        func isNestedChild(_ terminal: Terminal) -> Bool {
            terminal.parent.map { byAddress[$0] != nil } ?? false
        }

        for space in layout?.spaces ?? [] {
            var rows: [TerminalSection.Row] = []
            let multipleTabs = space.tabs.count > 1
            for (index, tab) in space.tabs.enumerated() {
                let tabName = tab.name.isEmpty ? "\(index + 1)" : tab.name
                for address in tab.terminals {
                    guard let terminal = byAddress[address] else { continue }
                    place(terminal, depth: 0, tab: multipleTabs ? tabName : nil, into: &rows)
                }
            }
            // Workers labeled for this space but without a pane (peeked agents).
            for terminal in terminals where terminal.labels["herdr.space"] == space.id && !isNestedChild(terminal) {
                place(terminal, depth: 0, tab: nil, into: &rows)
            }
            guard !rows.isEmpty else { continue }
            sections.append(TerminalSection(
                kind: .space(id: space.id), title: spaceName(space, rows: rows),
                subtitle: space.folder.isEmpty ? nil : abbreviate(space.folder), rows: rows))
        }

        // The rest: per remote machine (`box/t7`), then local terminals in no space.
        let rest = terminals.filter { !placed.contains($0.address) && !isNestedChild($0) }
        let machines = Dictionary(grouping: rest.filter { $0.address.contains("/") }) {
            String($0.address.split(separator: "/").first!)
        }
        for name in machines.keys.sorted() {
            var rows: [TerminalSection.Row] = []
            for terminal in machines[name]! { place(terminal, depth: 0, tab: nil, into: &rows) }
            sections.append(TerminalSection(kind: .machine(name: name), title: name, subtitle: "machine", rows: rows))
        }
        var other: [TerminalSection.Row] = []
        for terminal in rest where !terminal.address.contains("/") { place(terminal, depth: 0, tab: nil, into: &other) }
        // Children whose parent was not placed anywhere (should not happen, but never drop a terminal).
        for terminal in terminals where !placed.contains(terminal.address) { place(terminal, depth: 0, tab: nil, into: &other) }
        if !other.isEmpty {
            sections.append(TerminalSection(
                kind: .other, title: sections.isEmpty ? "Terminals" : "Other terminals", subtitle: nil, rows: other))
        }
        return sections
    }

    /// herdr-app's rule: the space's name, else its first terminal's folder, else the space's folder.
    static func spaceName(_ space: HerdrAppLayout.Space, rows: [TerminalSection.Row]) -> String {
        if !space.name.isEmpty { return space.name }
        let first = space.tabs.lazy.flatMap(\.terminals).compactMap { address in
            rows.first { $0.terminal.address == address }?.terminal
        }.first
        let folder = first.map { $0.foreground?.cwd ?? $0.cwd } ?? space.folder
        return folderName(folder)
    }

    static func folderName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/")
        if parts.count == 2, ["Users", "home"].contains(parts[0]) { return "~" }
        return parts.last.map(String.init) ?? path
    }

    static func abbreviate(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, ["Users", "home"].contains(parts[1]) {
            return (["~"] + parts.dropFirst(3)).joined(separator: "/")
        }
        return path
    }
}
