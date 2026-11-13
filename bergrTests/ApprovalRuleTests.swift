import Foundation
import Testing
@testable import bergr

/// The same cases as ApprovalRuleTests in scripts/test_bergr_notify.py (bergrTests/approval-rule-cases.json).
@MainActor
struct ApprovalRuleTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func cases() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("bergrTests/approval-rule-cases.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func sharedMatchCases() throws {
        let all = try cases()
        let ctx = try #require(all["context"] as? [String: String])
        for c in try #require(all["match"] as? [[String: Any]]) {
            let rule = ApprovalRule(machine: ctx["machine"]!, cwd: ctx["cwd"]!, agent: ctx["agent"]!,
                                    command: c["rule"] as! String, prefix: c["prefix"] as! Bool)
            let got = ApprovalRuleMatcher.matches(
                rule, machine: c["machine"] as? String ?? ctx["machine"]!, cwd: c["cwd"] as? String ?? ctx["cwd"]!,
                agent: c["agent"] as? String ?? ctx["agent"]!, command: c["command"] as! String)
            #expect(got == (c["expect"] as! Bool), "\(c)")
        }
    }

    @Test func sharedPromptCases() throws {
        for c in try #require(try cases()["prompt"] as? [[String: Any]]) {
            let got = ApprovalRuleMatcher.promptCommand(
                lines: c["lines"] as! [String], cols: c["cols"] as! Int, agent: c["agent"] as? String)
            #expect(got == c["expect"] as? String, "\(c["name"] ?? "")")
        }
    }

    @Test func prefixesOfferShorterWordRuns() {
        #expect(ApprovalRuleMatcher.prefixes(of: "npm test -- --watch") == ["npm test -- --watch", "npm test --", "npm test", "npm"])
        #expect(ApprovalRuleMatcher.prefixes(of: "npm test | sh").isEmpty)
        #expect(ApprovalRuleMatcher.prefixes(of: "rm -rf x").isEmpty)
    }

    private func entry(_ command: String?, cwd: String = "/p", host: String = "M1", answer: String = "Yes",
                       source: ApprovalEntry.Source = .card) -> ApprovalEntry {
        ApprovalEntry(date: .now, machine: "mac", agent: "claude-code", question: command ?? "q", answer: answer,
                      source: source, dangerous: false, command: command, cwd: cwd, hostID: host)
    }

    @Test func suggestionAfterThreeManualApprovalsInOnePlace() {
        let two = [entry("npm test"), entry("npm test")]
        #expect(ApprovalRuleMatcher.suggestions(two, rules: []).isEmpty)
        let three = two + [entry("npm test")]
        let s = ApprovalRuleMatcher.suggestions(three, rules: [])
        #expect(s.count == 1 && s[0].command == "npm test" && s[0].count == 3 && s[0].scope.cwd == "/p")
        // Different folders, No answers, rule answers and dangerous commands don't add up.
        let mixed = two + [entry("npm test", cwd: "/q"), entry("npm test", answer: "No"), entry("npm test", source: .rule)]
        #expect(ApprovalRuleMatcher.suggestions(mixed, rules: []).isEmpty)
        #expect(ApprovalRuleMatcher.suggestions(Array(repeating: entry("git reset --hard"), count: 5), rules: []).isEmpty)
        // Already covered by a rule: no suggestion.
        let rule = ApprovalRule(machine: "M1", cwd: "/p", agent: "claude-code", command: "npm", prefix: true)
        #expect(ApprovalRuleMatcher.suggestions(three, rules: [rule]).isEmpty)
    }

    @Test func storeRefusesUnsafeRulesAndDeduplicates() throws {
        let defaults = try #require(UserDefaults(suiteName: "ApprovalRuleTests-\(UUID())"))
        let store = ApprovalRuleStore(defaults: defaults)
        let scope = ApprovalScope(machine: "M1", machineName: "mac", cwd: "/p", agent: "claude-code")
        #expect(store.add(scope: scope, command: "npm test; rm x", prefix: false) == nil)
        #expect(store.add(scope: scope, command: "sudo ls", prefix: true) == nil)
        #expect(store.add(scope: ApprovalScope(machine: "M1", machineName: "", cwd: "", agent: "claude-code"),
                          command: "ls", prefix: false) == nil)
        let rule = try #require(store.add(scope: scope, command: "npm test", prefix: false))
        #expect(store.add(scope: scope, command: "npm test", prefix: false) == rule)
        #expect(ApprovalRuleStore(defaults: defaults).rules == [rule])
        store.remove(rule.id)
        #expect(ApprovalRuleStore.load(defaults).isEmpty)
    }

    @Test func syncPayloadCarriesOnlyThisMachinesRules() throws {
        let host = UUID()
        let mine = ApprovalRule(machine: host.uuidString, cwd: "/p", agent: "claude-code", command: "npm test", prefix: true)
        let other = ApprovalRule(machine: UUID().uuidString, cwd: "/p", agent: "claude-code", command: "ls", prefix: false)
        let data = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "phone", key: nil,
                                            host: host, rules: [mine, other])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let device = try #require(object["device"] as? [String: Any])
        let rules = try #require(device["rules"] as? [[String: Any]])
        #expect(rules.count == 1)
        #expect(rules[0]["command"] as? String == "npm test")
        #expect(rules[0]["prefix"] as? Bool == true)
        #expect(rules[0]["machine"] as? String == host.uuidString)
        #expect(rules[0]["cwd"] as? String == "/p")
        #expect(rules[0]["agent"] as? String == "claude-code")
        // Without rules given, the field stays out (older callers).
        let plain = PushRegistration.payload(token: "ab", secret: "s", enabled: true, name: "phone", key: nil, host: host)
        let device2 = try #require((try JSONSerialization.jsonObject(with: plain) as? [String: Any])?["device"] as? [String: Any])
        #expect(device2["rules"] == nil)
        #expect(PushRegistration.rulesFingerprint([mine], host: host) != PushRegistration.rulesFingerprint([], host: host))
    }

    @Test func helperAutoAnswersImportAsRuleEntries() throws {
        let id = UUID()
        let json = #"[{"id":"\#(id.uuidString)","at":100,"command":"npm test","machine":"M1","cwd":"/p","agent":"claude-code"},{"id":"bad"}]"#
        let new = AutoApprovalImport.entries(from: json, machine: "mac", existing: [])
        #expect(new.count == 1)
        #expect(new[0].source == .rule && new[0].command == "npm test" && new[0].machine == "mac")
        #expect(AutoApprovalImport.entries(from: json, machine: "mac", existing: new).isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("approvals-\(UUID()).json")
        ApprovalLog.merge(new, to: url)
        ApprovalLog.merge(new, to: url)
        #expect(ApprovalLog.load(from: url).map(\.source) == [.rule])
        try? FileManager.default.removeItem(at: url)
    }

    /// The dangerous patterns are kept by hand in two places; they must be the same list.
    @Test func dangerousPatternsMatchThePythonHelper() throws {
        let source = try String(contentsOf: Self.root.appendingPathComponent("bergr/Push/bergr-notify.py"), encoding: .utf8)
        let start = try #require(source.range(of: "DANGEROUS_RULES = ["))
        let end = try #require(source.range(of: "\n]\n", range: start.upperBound..<source.endIndex))
        let block = String(source[start.upperBound..<end.lowerBound])
        // Each entry: ("reason", r"pattern") (possibly over two lines).
        let regex = try NSRegularExpression(pattern: #"\(\s*"((?:[^"\\]|\\.)*)",\s*r"((?:[^"\\]|\\.)*)"\s*\)"#)
        let matches = regex.matches(in: block, range: NSRange(block.startIndex..., in: block))
        let python = matches.map { m in
            (String(block[Range(m.range(at: 1), in: block)!]), String(block[Range(m.range(at: 2), in: block)!]))
        }
        #expect(python.count == DangerousCommand.rules.count)
        for (p, s) in zip(python, DangerousCommand.rules) {
            #expect(p.0 == s.reason)
            #expect(p.1 == s.pattern)
        }
    }
}
