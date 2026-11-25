import SwiftUI

/// Codex shows a user's shell command in the terminal while it runs, then writes
/// the command and result to the transcript together. Read only the active block.
struct CodexLiveCommand: Equatable {
    let command: String
    let output: String

    static func read(_ lines: [String]) -> Self? {
        let rows = lines.suffix(40)
        func trim(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces) }
        guard let working = rows.lastIndex(where: {
            let line = trim($0)
            return line.hasPrefix("• Working (") && line.localizedCaseInsensitiveContains("esc to interrupt")
        }), !rows[(working + 1)...].contains(where: { trim($0).hasPrefix("• ") && trim($0) != "• Queued follow-up inputs" }),
           let header = rows[..<working].lastIndex(where: {
               trim($0).hasPrefix("• ") && trim($0) != "• Queued follow-up inputs"
           })
        else { return nil }
        let prefix = "• Running "
        let heading = trim(rows[header])
        guard heading.hasPrefix(prefix) else { return nil }

        var command = String(heading.dropFirst(prefix.count))
        var output: [String] = []
        var readingOutput = false
        for row in rows[(header + 1)..<working] {
            let line = trim(row)
            if line == "• Queued follow-up inputs" { break }
            if line.hasPrefix("└") {
                readingOutput = true
                output.append(trim(String(line.dropFirst())))
            } else if readingOutput {
                output.append(line)
            } else if !line.isEmpty {
                command += " " + line
            }
        }
        while output.last == "" { output.removeLast() }
        guard !command.isEmpty else { return nil }
        return Self(command: command, output: output.suffix(6).joined(separator: "\n"))
    }
}

/// Codex's queued inputs appear on screen before they're written to its transcript.
enum CodexQueuedInputs {
    static func read(_ lines: [String]) -> [String] {
        let rows = lines.suffix(40)
        guard let header = rows.lastIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "• Queued follow-up inputs"
        }) else { return [] }

        var entries: [String] = []
        for row in rows[(header + 1)...] {
            let line = row.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.contains("edit last queued message"),
                  !line.hasPrefix("•"), !line.hasPrefix("›"), !line.hasPrefix("─")
            else { break }
            if let marker = line.first, "↳└".contains(marker) {
                entries.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !entries.isEmpty, row.prefix(while: \.isWhitespace).count >= 2 {
                // On narrow terminals the attachment path can wrap mid-word.
                let last = entries.count - 1
                let wrapsPath = entries[last].hasPrefix("/tmp/bergr-images/") && !entries[last].contains(" ")
                    && !entries[last].split(separator: ".").suffix(1).contains(where: {
                        ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains($0.lowercased())
                    })
                entries[last] += (wrapsPath ? "" : " ") + line
            } else {
                break
            }
        }
        return entries.filter { !$0.isEmpty }
    }
}

struct CodexLiveCommandRow: View {
    let model: TerminalScreenModel
    let palette: ChatPalette

    var body: some View {
        if let activity = CodexLiveCommand.read(model.textLines) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Running command", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                Text(activity.command)
                    .font(.footnote.monospaced())
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if !activity.output.isEmpty {
                    Text(activity.output)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.secondary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(palette.bubble, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}
