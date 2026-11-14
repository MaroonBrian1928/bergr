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
    /// When the rule stops applying; nil never (and rules made before expiry existed).
    var expires: Date? = nil

    func isExpired(at now: Date = .now) -> Bool {
        expires.map { now >= $0 } ?? false
    }

    /// What the helper gets in push.json.
    var payload: [String: Any] {
        var out: [String: Any] = ["id": id.uuidString, "machine": machine, "cwd": cwd, "agent": agent,
                                  "command": command, "prefix": prefix]
        if let expires { out["expires"] = expires.timeIntervalSince1970 }
        return out
    }
}

/// How long a new "always allow" rule lasts (Settings → Approvals).
nonisolated enum RuleLifetime: Int, CaseIterable, Identifiable, Sendable {
    case day = 1, week = 7, month = 30, never = 0
    static let key = "bergr.approvalRuleLifetime"
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .day: "1 day"
        case .week: "7 days"
        case .month: "30 days"
        case .never: "Never"
        }
    }

    func expiry(from now: Date = .now) -> Date? {
        self == .never ? nil : now.addingTimeInterval(TimeInterval(rawValue) * 86_400)
    }

    static func current(_ defaults: UserDefaults = .standard) -> RuleLifetime {
        defaults.object(forKey: key) == nil ? .month : RuleLifetime(rawValue: defaults.integer(forKey: key)) ?? .month
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
    /// An expired rule never matches.
    static func matches(_ rule: ApprovalRule, machine: String, cwd: String, agent: String, command: String,
                        now: Date = .now) -> Bool {
        guard rule.machine == machine, rule.cwd == cwd, rule.agent == agent, !rule.isExpired(at: now),
              !rule.machine.isEmpty, !rule.cwd.isEmpty, isEligible(rule.command), isEligible(command)
        else { return false }
        if command == rule.command { return true }
        return rule.prefix && command.hasPrefix(rule.command + " ")
    }

    /// Programs that can run anything: a one-word prefix of these would allow every command.
    static let broadPrograms: Set<String> = [
        "npm", "npx", "yarn", "pnpm", "bun", "node", "python", "python3", "pip", "uv", "ruby", "bundle",
        "go", "cargo", "make", "git", "sh", "bash", "zsh", "docker", "kubectl",
    ]

    /// The prefixes a user can pick for a command: the command itself, then shorter word runs
    /// ("npm test -- --watch" → "npm test -- --watch", "npm test --", "npm test"). Never a lone
    /// interpreter, package manager or VCS ("npm", "git", "python").
    static func prefixes(of command: String) -> [String] {
        let words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard isEligible(command), !words.contains(where: \.isEmpty) else { return [] }
        return (1...words.count).reversed().map { words.prefix($0).joined(separator: " ") }
            .filter { !isBroadProgram($0) }
    }

    /// One word naming a program in `broadPrograms` (also as a path, e.g. /usr/bin/python3).
    static func isBroadProgram(_ prefix: String) -> Bool {
        guard !prefix.contains(" ") else { return false }
        let name = prefix.split(separator: "/").last.map(String.init) ?? prefix
        return broadPrograms.contains(name.lowercased())
    }

    /// A warning for a prefix this short: nil for two words or more.
    static func prefixWarning(_ prefix: String) -> String? {
        prefix.split(separator: " ").count < 2 ? "This allows any `\(prefix)` command in this folder" : nil
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
        lifetime = RuleLifetime.current(defaults)
    }

    nonisolated static func load(_ defaults: UserDefaults = .standard) -> [ApprovalRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ApprovalRule].self, from: data)) ?? []
    }

    /// How long new rules last.
    var lifetime: RuleLifetime {
        didSet { defaults.set(lifetime.rawValue, forKey: RuleLifetime.key) }
    }

    /// A one-word prefix of an interpreter, package manager or VCS is refused. An existing expired
    /// rule for the same thing is renewed.
    @discardableResult
    func add(scope: ApprovalScope, command: String, prefix: Bool, now: Date = .now) -> ApprovalRule? {
        guard ApprovalRuleMatcher.isEligible(command), !scope.machine.isEmpty, !scope.cwd.isEmpty,
              !(prefix && ApprovalRuleMatcher.isBroadProgram(command)) else { return nil }
        if let same = rules.first(where: {
            $0.machine == scope.machine && $0.cwd == scope.cwd && $0.agent == scope.agent
                && $0.command == command && $0.prefix == prefix
        }) {
            return same.isExpired(at: now) ? renew(same.id, now: now) : same
        }
        var rule = ApprovalRule(machine: scope.machine, cwd: scope.cwd, agent: scope.agent, command: command, prefix: prefix)
        rule.created = now
        rule.expires = lifetime.expiry(from: now)
        rules.append(rule)
        save()
        return rule
    }

    /// The user's "always ask" patterns (see `AskPatterns`), kept where the extensions read them.
    private(set) var askPatterns: [String] = AskPatterns.load()

    func addAskPattern(_ pattern: String) {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !askPatterns.contains(p) else { return }
        askPatterns.append(p)
        AskPatterns.save(askPatterns)
    }

    func removeAskPattern(_ pattern: String) {
        askPatterns.removeAll { $0 == pattern }
        AskPatterns.save(askPatterns)
    }

    /// Starts the rule's lifetime again from now.
    @discardableResult
    func renew(_ id: UUID, now: Date = .now) -> ApprovalRule? {
        guard let i = rules.firstIndex(where: { $0.id == id }) else { return nil }
        rules[i].expires = lifetime.expiry(from: now)
        save()
        return rules[i]
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
                question: command, answer: item["answer"] as? String ?? "Yes",
                source: (item["source"] as? String).flatMap(ApprovalEntry.Source.init(rawValue:)) ?? .rule, dangerous: false,
                command: command, cwd: item["cwd"] as? String, hostID: item["machine"] as? String)
        }
    }
}
