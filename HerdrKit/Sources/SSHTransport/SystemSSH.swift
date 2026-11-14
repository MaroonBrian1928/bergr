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

    /// `ssh -N -L`: the same options as a command, forwarding instead of running one.
    static func forwardArguments(target: SSHTarget, localPort: Int, remotePort: Int) throws -> [String] {
        var arguments = try arguments(target: target, command: "")
        arguments.removeLast()
        arguments[0] = "-N"
        let options = ["-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:\(localPort):localhost:\(remotePort)"]
        arguments.insert(contentsOf: options, at: 1)
        return arguments
    }

    /// Starts `ssh -N -L` on a free local port and waits until it listens.
    func forward(remotePort: Int) async throws -> PortForward {
        let localPort = try Self.freeLocalPort()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = try Self.forwardArguments(target: target, localPort: localPort, remotePort: remotePort)
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let id = UUID()
        try lock.withLock {
            guard !closed else { throw ChannelError.ioOnClosedChannel }
            try process.run()
            processes[id] = process
        }
        let forward = PortForward(localPort: localPort) { [weak self] in
            if process.isRunning { process.terminate() }
            _ = self?.lock.withLock { self?.processes.removeValue(forKey: id) }
        }
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                forward.close()
                let message = String(decoding: errors.fileHandleForReading.availableData, as: UTF8.self)
                throw SSHTransportError.commandFailed(
                    exitCode: Int(process.terminationStatus),
                    stderr: message.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if Self.canConnect(port: localPort) { return forward }
            try await Task.sleep(for: .milliseconds(100))
        }
        forward.close()
        throw SSHTransportError.commandFailed(exitCode: 255, stderr: "SSH did not open the port forward in time.")
    }

    /// A port nothing listens on now (the kernel picks it).
    static func freeLocalPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ChannelError.ioOnClosedChannel }
        defer { Darwin.close(fd) }
        var address = loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ChannelError.ioOnClosedChannel }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func canConnect(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = loopback(port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private static func loopback(port: Int) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
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
