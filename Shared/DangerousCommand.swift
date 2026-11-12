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
         #"\bgit\s+push\b[^;&|\n]*\s(?:--force(?:-with-lease)?\b|-[a-z]*f[a-z]*\b)"#),
        ("hard reset (git reset --hard)", #"\bgit\s+reset\b[^;&|\n]*--hard\b"#),
        ("git clean -f deletes untracked files", #"\bgit\s+clean\b[^;&|\n]*\s-[a-z]*f"#),
        ("runs as root (sudo)", #"\bsudo\s"#),
        ("formats a disk (mkfs)", #"\bmkfs(?:\.\w+)?\b"#),
        ("raw disk write (dd if=)", #"\bdd\s+(?:\S+\s+)*?if="#),
        ("drops or empties a database (DROP / TRUNCATE)", #"\bdrop\s+(?:table|database)\b|\btruncate\b"#),
        ("opens permissions to everyone (chmod -R 777)",
         #"\bchmod\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))[^;&|\n]*\b777\b"#),
        ("writes straight to a disk (> /dev/sd)", #">\s*/dev/sd"#),
        ("destructive migration (reset / rollback / drop)",
         #"\bmigrate\b[^;&|\n]*\b(?:reset|rollback|drop)\b"#),
    ]

    private static let compiled: [(reason: String, regex: NSRegularExpression)] = rules.compactMap { rule in
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return nil }
        return (rule.reason, regex)
    }

    /// Why this text is dangerous, or nil.
    static func check(_ text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        return compiled.first { $0.regex.firstMatch(in: text, range: range) != nil }?.reason
    }
}
