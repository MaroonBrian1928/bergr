import Foundation

/// Recognises commands that are hard to undo, in the text of a permission prompt. The same
/// patterns live in bergr/Push/bergr-notify.py (keep them in step): an alert about one of these
/// gets no approve buttons, and the chat's card asks to confirm.
nonisolated enum DangerousCommand {
    private static let rest = #"[^;&|\n]*"#

    /// (reason, pattern); patterns are case-insensitive.
    static let rules: [(reason: String, pattern: String)] = [
        ("recursive force delete (rm -rf)",
         #"\brm\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))(?=[^;&|\n]*\s(?:-[a-z]*f|--force))"#),
        ("force push (git push --force)",
         #"\bgit\s+push\b[^;&|\n]*\s(?:--force(?:-with-lease)?\b|-[a-z]*f[a-z]*\b|\+[^\s+])"#),
        ("hard reset (git reset --hard)", #"\bgit\s+reset\b[^;&|\n]*--hard\b"#),
        ("git clean -f deletes untracked files", #"\bgit\s+clean\b[^;&|\n]*\s(?:-[a-z]*f|--force\b)"#),
        ("discards uncommitted changes (git checkout .)", #"\bgit\s+checkout\b[^;&|\n]*\s(?:--\s+)?\.(?=[\s;&|)]|$)"#),
        ("discards uncommitted changes (git restore)",
         #"\bgit\s+restore\b(?:(?![^;&|\n]*\s--staged\b)|(?=[^;&|\n]*\s--worktree\b))"#),
        ("deletes a branch (git branch -D)", #"\bgit\s+branch\b[^;&|\n]*(?-i:\s-[a-zA-Z]*D)"#),
        ("deletes files (find -delete)", #"\bfind\b[^;&|\n]*\s(?:-delete\b|-exec(?:dir)?\s+rm\b)"#),
        ("runs as root (sudo)", #"\bsudo\s"#),
        ("formats a disk (mkfs)", #"\bmkfs(?:\.\w+)?\b"#),
        ("raw disk write (dd if=)", #"\bdd\s+(?:\S+\s+)*?if="#),
        ("raw disk write (dd of=/dev/)", #"\bdd\b[^;&|\n]*\bof=/dev/(?!null\b|stdout\b|stderr\b)"#),
        ("drops or empties a database (DROP / TRUNCATE)", #"\bdrop\s+(?:table|database)\b|\btruncate\b"#),
        ("deletes database rows (DELETE FROM)", #"\bdelete\s+from\b"#),
        ("opens permissions to everyone (chmod -R 777)",
         #"\bchmod\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))[^;&|\n]*\b777\b"#),
        ("changes owners recursively (chown -R)", #"\bchown\b[^;&|\n]*\s(?:-[a-z]*r[a-z]*|--recursive)\b"#),
        ("writes straight to a disk (> /dev/sd)", #">\s*/dev/(?:sd|nvme|disk|hd|mmcblk)"#),
        ("destructive migration (reset / rollback / drop)",
         #"\bmigrate\b[^;&|\n]*\b(?:reset|rollback|drop)\b"#),
        ("destroys infrastructure (terraform destroy)", #"\b(?:terraform|tofu)\b[^;&|\n]*\s-?destroy\b"#),
        ("deletes cluster resources (kubectl delete)", #"\bkubectl\b[^;&|\n]*\sdelete\b"#),
        ("deletes containers or data (docker prune / rm -f)",
         #"\bdocker\s+(?:system\s+prune|volume\s+(?:rm|prune)\b|(?:container\s+)?rm\b[^;&|\n]*\s(?:-[a-z]*f[a-z]*|--force)\b)"#),
        ("runs a script from the internet (curl | sh)",
         #"\b(?:curl|wget)\b[^;&\n]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|python[0-9.]*)\b|\b(?:sh|bash|zsh)\s+<\(\s*(?:curl|wget)\b"#),
        ("shuts down the machine (shutdown / reboot)",
         #"(?:^|[;&|(\n:]|\bsudo|\bsystemctl|\bdoas)\s*(?:shutdown|reboot|halt|poweroff)\b"#),
    ]

    private static let compiled: [(reason: String, regex: NSRegularExpression)] = rules.compactMap { rule in
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return nil }
        return (rule.reason, regex)
    }

    /// Why this text is dangerous, or nil.
    /// The user's "always ask" patterns count too.
    static func check(_ text: String, ask: [String] = AskPatterns.load()) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        if let reason = compiled.first(where: { $0.regex.firstMatch(in: text, range: range) != nil })?.reason {
            return reason
        }
        return AskPatterns.matches(text, ask) ? AskPatterns.reason : nil
    }
}

/// The user's own "always ask" patterns (Settings → Approvals): plain text or a simple glob
/// (`*` any run, `?` one character), case-insensitive, anywhere in the text. A match is treated as
/// dangerous: no Yes on cards, notifications or rows, and the helper never auto-answers it
/// (`ask_match` in bergr-notify.py; both follow bergrTests/approval-rule-cases.json).
nonisolated enum AskPatterns {
    static let key = "bergr.askPatterns"
    static let reason = "on your always-ask list"

    /// The App Group's defaults when there is one, so the extensions see the same list.
    static var defaults: UserDefaults {
        BergrAppGroup.id.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    static func load(_ defaults: UserDefaults = AskPatterns.defaults) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func save(_ patterns: [String], to defaults: UserDefaults = AskPatterns.defaults) {
        defaults.set(patterns, forKey: key)
    }

    static func regex(_ pattern: String) -> NSRegularExpression? {
        let body = pattern.map { c -> String in
            c == "*" ? ".*" : c == "?" ? "." : NSRegularExpression.escapedPattern(for: String(c))
        }.joined()
        return try? NSRegularExpression(pattern: body, options: [.caseInsensitive])
    }

    static func matches(_ text: String, _ patterns: [String]) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { p in
            let p = p.trimmingCharacters(in: .whitespacesAndNewlines)
            return !p.isEmpty && regex(p)?.firstMatch(in: text, range: range) != nil
        }
    }
}
