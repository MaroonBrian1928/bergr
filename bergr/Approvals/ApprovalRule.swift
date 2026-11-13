import Foundation
import Observation

/// "Always allow this here": one command (or a prefix the user chose) on one machine, in one project
/// folder, for one kind of agent. The machine's helper (bergr-notify.py, `rule_matches` and
/// `prompt_command`) answers Yes for it; both sides follow the same cases in
/// bergrTests/approval-rule-cases.json.
nonisolated struct ApprovalRule: Codable, Equatable, Identifiable, Hashable, Sendable {
    var id = UUID()
    /// Bergr's id for the machine (`Host.id`), as the helper knows it (`host_id`).
    var machine: String
    var cwd: String
    var agent: String
    var command: String
    /// Also covers the command followed by a space and more arguments.
    var prefix: Bool
    var created = Date()

    /// What the helper gets in push.json.
    var payload: [String: Any] {
        ["id": id.uuidString, "machine": machine, "cwd": cwd, "agent": agent, "command": command, "prefix": prefix]
    }
}

/// Where a prompt is being answered: what a rule made from it is scoped to.
nonisolated struct ApprovalScope: Equatable, Hashable, Sendable {
    var machine: String
    var machineName: String
    var cwd: String
    var agent: String
}

nonisolated enum ApprovalRuleMatcher {
    /// A command with any of these is never answered by a rule (chaining, pipes, substitution,
    /// redirection, more than one line).
    static let metacharacters: Set<Character> = [";", "&", "|", "$", "`", ">", "<", "\n", "\r"]

    /// Whether a command is plain enough to be covered by a rule at all.
    static func isEligible(_ command: String) -> Bool {
        !command.isEmpty && !command.unicodeScalars.contains { metacharacters.contains(Character($0)) }
            && DangerousCommand.check(command) == nil
    }

    /// Exact command, or the rule's prefix followed by the end or a space. Never a command with
    /// shell metacharacters, never a dangerous one, never another machine, folder or agent.
    static func matches(_ rule: ApprovalRule, machine: String, cwd: String, agent: String, command: String) -> Bool {
        guard rule.machine == machine, rule.cwd == cwd, rule.agent == agent,
              !rule.machine.isEmpty, !rule.cwd.isEmpty, isEligible(rule.command), isEligible(command)
        else { return false }
        if command == rule.command { return true }
        return rule.prefix && command.hasPrefix(rule.command + " ")
    }

    /// The prefixes a user can pick for a command: the command itself, then shorter word runs
    /// ("npm test -- --watch" → "npm test -- --watch", "npm test --", "npm test", "npm").
    static func prefixes(of command: String) -> [String] {
        let words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard isEligible(command), !words.contains(where: \.isEmpty) else { return [] }
        return (1...words.count).reversed().map { words.prefix($0).joined(separator: " ") }
    }

    private static let borders: Set<Character> = Set("│┃║╭╮╰╯┌┐└┘─━═┆┊╎|")
    private static let markers: Set<Character> = Set("❯›>▶►→➤▸")

    static func clean(_ line: String) -> String {
        var chars = Substring(line)
        while let f = chars.first, f.isWhitespace || borders.contains(f) { chars = chars.dropFirst() }
        while let l = chars.last, l.isWhitespace || borders.contains(l) { chars = chars.dropLast() }
        return String(chars)
    }

    /// (number, label, selected) for "❯ 1. Yes", or nil.
    private static func option(_ text: String) -> (Int, String, Bool)? {
        var rest = Substring(text)
        var selected = false
        if let f = rest.first, markers.contains(f) {
            selected = true
            rest = rest.dropFirst().drop { $0 == " " }
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2, let n = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix(". ") else { return nil }
        let label = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return label.isEmpty ? nil : (n, label, selected)
    }

    /// The command of Claude Code's Bash permission prompt at the bottom of the screen, when the
    /// screen is exactly that prompt with the cursor on "1. Yes"; nil whenever unsure. Mirrors
    /// `prompt_command` in bergr-notify.py.
    static func promptCommand(lines raw: [String], cols: Int, agent: String?) -> String? {
        guard agent == "claude-code" else { return nil }
        var lines = raw.map(clean)
        while let last = lines.last, last.isEmpty || last.hasPrefix("Esc to cancel") { lines.removeLast() }
        // The menu: 1…n from the bottom, n ≥ 2, the cursor on 1.
        var menu: [(Int, String, Bool)] = []
        while let last = lines.last, let o = option(last) {
            menu.insert(o, at: 0)
            lines.removeLast()
        }
        guard menu.count >= 2, menu.enumerated().allSatisfy({ $0.element.0 == $0.offset + 1 }),
              menu[0].1 == "Yes", menu[0].2, !menu.dropFirst().contains(where: \.2) else { return nil }
        guard lines.popLast() == "Do you want to proceed?" else { return nil }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var content: [String] = []
        while let last = lines.last, !last.isEmpty, last != "Bash command" {
            content.insert(last, at: 0)
            lines.removeLast()
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard lines.last == "Bash command", (1...2).contains(content.count) else { return nil }
        let command = content[0]
        // A line this long may have wrapped: the second line could be the rest of the command.
        guard command.count + 8 <= cols, isEligible(command) else { return nil }
        return command
    }

    /// Manually approved commands (from the log) seen `threshold`+ times in one place without a rule.
    static func suggestions(
        _ entries: [ApprovalEntry], rules: [ApprovalRule], threshold: Int = 3
    ) -> [(scope: ApprovalScope, command: String, count: Int)] {
        var counts: [String: (ApprovalScope, String, Int)] = [:]
        var order: [String] = []
        for e in entries where e.source != .rule && e.answer == "Yes" {
            guard let command = e.command, let cwd = e.cwd, let machine = e.hostID, isEligible(command) else { continue }
            let scope = ApprovalScope(machine: machine, machineName: e.machine, cwd: cwd, agent: e.agent)
            if rules.contains(where: { matches($0, machine: machine, cwd: cwd, agent: e.agent, command: command) }) { continue }
            let key = [machine, cwd, e.agent, command].joined(separator: "\u{1}")
            if counts[key] == nil { order.append(key) }
            counts[key] = (scope, command, (counts[key]?.2 ?? 0) + 1)
        }
        return order.compactMap { counts[$0] }.filter { $0.2 >= threshold }.map { (scope: $0.0, command: $0.1, count: $0.2) }
    }
}

/// The rules, kept on this device and sent to each machine with the push registration.
@MainActor @Observable
final class ApprovalRuleStore {
    static let shared = ApprovalRuleStore()
    static let key = "bergr.approvalRules"
    private let defaults: UserDefaults
    private(set) var rules: [ApprovalRule]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rules = Self.load(defaults)
    }

    nonisolated static func load(_ defaults: UserDefaults = .standard) -> [ApprovalRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ApprovalRule].self, from: data)) ?? []
    }

    @discardableResult
    func add(scope: ApprovalScope, command: String, prefix: Bool) -> ApprovalRule? {
        guard ApprovalRuleMatcher.isEligible(command), !scope.machine.isEmpty, !scope.cwd.isEmpty else { return nil }
        if let same = rules.first(where: {
            $0.machine == scope.machine && $0.cwd == scope.cwd && $0.agent == scope.agent
                && $0.command == command && $0.prefix == prefix
        }) { return same }
        let rule = ApprovalRule(machine: scope.machine, cwd: scope.cwd, agent: scope.agent, command: command, prefix: prefix)
        rules.append(rule)
        save()
        return rule
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: Self.key) }
    }

    /// What a machine's registration carries: only its own rules.
    nonisolated static func payload(_ rules: [ApprovalRule], host: UUID?) -> [[String: Any]] {
        guard let host else { return [] }
        return rules.filter { $0.machine == host.uuidString }.map(\.payload)
    }
}

/// Auto-answers the helper logged on a machine (`~/.config/bergr/auto-approvals.json`), brought into
/// this device's approvals log when the app connects.
nonisolated enum AutoApprovalImport {
    static let readCommand = "cat ~/.config/bergr/auto-approvals.json 2>/dev/null"

    /// Entries from the helper's file not yet in the log (by id).
    static func entries(from output: String, machine: String, existing: [ApprovalEntry]) -> [ApprovalEntry] {
        guard let data = output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        let known = Set(existing.map(\.id))
        return list.compactMap { item in
            guard let idText = item["id"] as? String, let id = UUID(uuidString: idText), !known.contains(id),
                  let command = item["command"] as? String, let at = item["at"] as? Double else { return nil }
            return ApprovalEntry(
                id: id, date: Date(timeIntervalSince1970: at), machine: machine, agent: item["agent"] as? String ?? "",
                question: command, answer: "Yes", source: .rule, dangerous: false,
                command: command, cwd: item["cwd"] as? String, hostID: item["machine"] as? String)
        }
    }
}
