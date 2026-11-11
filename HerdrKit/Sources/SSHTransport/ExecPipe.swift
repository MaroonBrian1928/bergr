@preconcurrency import Citadel
import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// A running remote command: write to its stdin, read its stdout.
///
/// Stderr is collected and reported if the command fails.
public final class ExecPipe: @unchecked Sendable {
    /// The command's stdout. Ends when the command exits; throws
    /// `SSHTransportError.commandFailed` on a non-zero exit.
    public let output: AsyncThrowingStream<Data, Error>

    private let writeImpl: @Sendable (Data) async throws -> Void
    private let closeImpl: @Sendable () -> Void

    private init(output: AsyncThrowingStream<Data, Error>, writer: TTYStdinWriter, lifetime: Lifetime) {
        self.output = output
        self.writeImpl = { try await writer.write(ByteBuffer(bytes: $0)) }
        self.closeImpl = { lifetime.cancel() }
    }

    /// A pipe that is not an SSH channel: a command run on this machine (the Mac's "This Mac").
    public init(
        output: AsyncThrowingStream<Data, Error>,
        write: @escaping @Sendable (Data) async throws -> Void,
        close: @escaping @Sendable () -> Void
    ) {
        self.output = output
        self.writeImpl = write
        self.closeImpl = close
    }

    public func write(_ data: Data) async throws {
        try await writeImpl(data)
    }

    /// Closes the channel. The remote command sees EOF / hangup.
    public func close() {
        closeImpl()
    }

    static func open(command: String, on client: SSHClient) async throws -> ExecPipe {
        let (output, outputContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let lifetime = Lifetime()

        // Citadel scopes the channel to a closure; keep that closure running in a
        // task for as long as the pipe lives, and hand the writer out once it starts.
        let writer = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<TTYStdinWriter, Error>) in
            let once = Once(ready)
            lifetime.set(Task {
                var stderr = Data()
                do {
                    try await client.withExec(command) { inbound, outbound in
                        once.resume(with: .success(outbound))
                        do {
                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let buffer): outputContinuation.yield(Data(buffer.readableBytesView))
                                case .stderr(let buffer): stderr.append(contentsOf: buffer.readableBytesView)
                                }
                            }
                        } catch let failed as SSHClient.CommandFailed {
                            throw SSHTransportError.commandFailed(
                                exitCode: failed.exitCode,
                                stderr: String(decoding: stderr, as: UTF8.self)
                                    .trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    outputContinuation.finish()
                } catch {
                    once.resume(with: .failure(error))
                    outputContinuation.finish(throwing: Task.isCancelled ? CancellationError() : error)
                }
            })
        }
        return ExecPipe(output: output, writer: writer, lifetime: lifetime)
    }
}

/// Owns the task that keeps the exec channel open.
private final class Lifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock {
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancelled = true
            return self.task
        }
        task?.cancel()
    }
}

/// Resumes a continuation exactly once.
private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<T, Error>) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

// It only holds a NIO `Channel`, which is Sendable.
extension TTYStdinWriter: @retroactive @unchecked Sendable {}
