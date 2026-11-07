import Foundation
import SSHTransport

extension HostSession {
    /// Installs Bergr's Claude Code status line on the machine (`setup-statusline.py`), so Claude
    /// saves its context window and plan limits where the chat helper reads them. Returns what it
    /// changed, one line each.
    func setUpClaudeStatusLine() async throws -> [String] {
        guard let installer = Self.bundled("setup-statusline"), let script = Self.bundled("statusline-herdr") else {
            throw StatusLineError.failed("The setup files are missing from the app.")
        }
        let command = "python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' "
            + Data(installer.utf8).base64EncodedString() + " " + Data(script.utf8).base64EncodedString()
        let pipe = try await openExec(command)
        defer { pipe.close() }
        var buffer = Data()
        for try await chunk in pipe.output {
            buffer.append(chunk)
            if buffer.contains(0x0A) { break }
        }
        guard let line = String(data: buffer, encoding: .utf8)?.split(separator: "\n").first,
              let reply = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw StatusLineError.failed("The machine didn't answer. Is python3 installed there?")
        }
        guard reply["ok"] as? Bool == true else {
            throw StatusLineError.failed(reply["error"] as? String ?? "Setup failed on the machine.")
        }
        return reply["done"] as? [String] ?? []
    }

    private static func bundled(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "py").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    enum StatusLineError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let message) = self { message } else { nil } }
    }
}
