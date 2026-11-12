#if os(macOS)
import Foundation
import NIOCore

/// Each exec has an OpenSSH process. Its agent signs with the existing Mac key; private key
/// material and passphrases never enter Bergr. Pipes preserve herdr-core's binary protocol.
final class SystemSSH: @unchecked Sendable {
    let target: SSHTarget
    private let lock = NSLock()
    private var processes: [UUID: Process] = [:]
    private var closed = false

    init(target: SSHTarget) { self.target = target }

    var isClosed: Bool { lock.withLock { closed } }

    static func arguments(target: SSHTarget, command: String) throws -> [String] {
        guard !target.host.isEmpty, !target.host.hasPrefix("-"),
              !target.username.isEmpty, !target.username.hasPrefix("-"),
              !target.host.contains("\n"), !target.username.contains("\n"),
              (1...65535).contains(target.port) else {
            throw SSHTransportError.commandFailed(exitCode: 255, stderr: "Invalid SSH address, username or port.")
        }
        return ["-T", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                "-o", "UpdateHostKeys=no", "-o", "ConnectTimeout=15",
                "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=2",
                "-p", String(target.port), "-l", target.username, "--", target.host, command]
    }

    func openExec(_ command: String) throws -> ExecPipe {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try Self.arguments(target: target, command: command)
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        let id = UUID()
        // Starting under the lock prevents close() racing between registration and launch.
        try lock.withLock {
            guard !closed else { throw ChannelError.ioOnClosedChannel }
            try process.run()
            processes[id] = process
        }
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let stderr = StderrBuffer()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global().async {
            defer { drained.leave() }
            while true {
                let chunk = errors.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                stderr.append(chunk)
            }
        }
        DispatchQueue.global().async { [self] in
            // availableData returns as soon as any bytes arrive; read(upToCount:) can wait
            // to fill its buffer on macOS, deadlocking a request/response protocol.
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                continuation.yield(chunk)
            }
            process.waitUntilExit()
            drained.wait()
            if process.terminationStatus == 0 {
                continuation.finish()
            } else {
                continuation.finish(throwing: SSHTransportError.commandFailed(
                    exitCode: Int(process.terminationStatus), stderr: stderr.message))
            }
            _ = lock.withLock { processes.removeValue(forKey: id) }
        }
        return ExecPipe(output: stream, write: { try input.fileHandleForWriting.write(contentsOf: $0) }, close: {
            continuation.finish(throwing: CancellationError())
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        })
    }

    func close() {
        let running = lock.withLock {
            closed = true
            let running = Array(processes.values)
            processes.removeAll()
            return running
        }
        for process in running where process.isRunning { process.terminate() }
    }
}

private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk.prefix(max(0, 65536 - data.count))) }
    }
    var message: String {
        lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
#endif
