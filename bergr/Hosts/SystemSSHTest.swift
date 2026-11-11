import Foundation
import HerdrKit

/// "Open in terminal" on the Mac runs the system `ssh`, which can't use Bergr's Secure Enclave key.
/// This checks that plain `ssh <host>` works without asking anything (keys, agent, config).
enum SystemSSHTest {
    enum Outcome: Equatable {
        case works
        case failed(String)
        case unavailable(String)
    }

    /// Arguments for a non-interactive login that just runs `true`. nil when the address could be
    /// mistaken for an option.
    static func arguments(for target: SSHTarget) -> [String]? {
        let host = target.host.trimmingCharacters(in: .whitespaces)
        let user = target.username.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !host.hasPrefix("-"), !user.hasPrefix("-"), !host.contains(where: \.isWhitespace),
              !user.contains(where: \.isWhitespace), (1...65535).contains(target.port)
        else { return nil }
        let destination = user.isEmpty ? host : "\(user)@\(host)"
        return [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-p", String(target.port), "--", destination, "true",
        ]
    }

    /// What to tell the user for `ssh`'s stderr.
    static func explain(status: Int32, stderr: String) -> Outcome {
        if status == 0 { return .works }
        let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        if lower.contains("permission denied") {
            return .failed("The system ssh can't sign in. Add your own key to the machine (ssh-copy-id), "
                + "or load it into ssh-agent. Bergr's key can't be used by the system ssh.")
        }
        if lower.contains("host key verification failed") {
            return .failed("The system ssh doesn't know this machine yet. Run ssh once in a terminal to accept its host key.")
        }
        return .failed(text.isEmpty ? "ssh exited with status \(status)." : text)
    }

    static func run(_ target: SSHTarget) async -> Outcome {
        #if os(macOS)
        guard let arguments = arguments(for: target) else {
            return .unavailable("Enter a valid address first.")
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = arguments
            let error = Pipe()
            process.standardError = error
            process.standardOutput = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let text = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: explain(status: finished.terminationStatus, stderr: text))
            }
            do { try process.run() } catch {
                continuation.resume(returning: .unavailable(error.localizedDescription))
            }
        }
        #else
        return .unavailable("Only available on the Mac.")
        #endif
    }
}
