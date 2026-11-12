import Foundation
import NIOCore
import SSHTransport

extension HostSession {
    /// Runs a short command on the machine and returns what it printed; gives up after
    /// `timeout` so a stuck channel can't hang the caller.
    func commandOutput(_ command: String, input: Data? = nil, timeout: Duration = .seconds(20)) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let pipe = try await self.openExec(command)
                defer { pipe.close() }
                if let input { try await pipe.write(input) }
                var out = Data()
                do {
                    for try await chunk in pipe.output { out.append(chunk) }
                } catch {
                    // Citadel can report the channel as closed after the command has answered and
                    // exited (NIO ChannelError.alreadyClosed / inputClosed / eof, seen with Citadel
                    // 0.12); the answer is complete, so keep it — even when the command printed
                    // nothing (e.g. a lookup that found nothing), which used to surface as
                    // "NIOCore.ChannelError error 6" instead of an empty answer.
                    if out.isEmpty, !Self.isChannelClosed(error) { throw error }
                }
                return String(decoding: out, as: UTF8.self)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CommandTimeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}

extension HostSession {
    /// Whether the error only says the channel closed (end of output), not that it failed.
    nonisolated static func isChannelClosed(_ error: Error) -> Bool {
        guard let error = error as? ChannelError else { return false }
        switch error {
        case .alreadyClosed, .inputClosed, .outputClosed, .ioOnClosedChannel, .eof: return true
        default: return false
        }
    }
}

struct CommandTimeout: LocalizedError {
    var errorDescription: String? { "The machine didn't answer in time." }
}
