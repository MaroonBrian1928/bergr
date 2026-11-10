import Foundation
import SSHTransport

extension HostSession {
    /// Runs a short command on the machine and returns what it printed; gives up after
    /// `timeout` so a stuck channel can't hang the caller.
    func commandOutput(_ command: String, timeout: Duration = .seconds(20)) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let pipe = try await self.openExec(command)
                defer { pipe.close() }
                var out = Data()
                do {
                    for try await chunk in pipe.output { out.append(chunk) }
                } catch {
                    // Citadel can report the channel as already closed after the command has
                    // answered and exited (NIO ChannelError.alreadyClosed, seen with Citadel
                    // 0.12); the answer is complete, so keep it.
                    if out.isEmpty { throw error }
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

struct CommandTimeout: LocalizedError {
    var errorDescription: String? { "The machine didn't answer in time." }
}
