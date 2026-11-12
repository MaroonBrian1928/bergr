import Foundation
import SSHTransport

/// A byte pipe to `herdr-core connect`.
public protocol ByteTransport: Sendable {
    var incoming: AsyncThrowingStream<Data, Error> { get }
    func send(_ data: Data) async throws
    func close()
}

extension ExecPipe: ByteTransport {
    public var incoming: AsyncThrowingStream<Data, Error> { output }
    public func send(_ data: Data) async throws { try await write(data) }
}

public enum HerdrCore {
    public enum Platform: Sendable { case unix, windows }

    /// Works with either cmd.exe or PowerShell as the Windows SSH default shell.
    /// A Unix shell reports command-not-found, so platform detection needs no PTY.
    public static let windowsProbe = "cmd.exe /d /c ver"

    public static func platform(probeOutput: String) -> Platform {
        probeOutput.contains("Microsoft Windows") ? .windows : .unix
    }
    /// The protocol generation this client speaks.
    public static let generation = 1

    /// Shell line that connects stdin/stdout to the core on an SSH host. Same as
    /// herdr-core's own `hc machine add` (see `machines.rs`, `fn pipe`): find
    /// `herdr-core` on PATH or in `~/.local/bin`, then `exec herdr-core connect`.
    public static func connectCommand(session: String? = nil, platform: Platform = .unix) -> String {
        if platform == .windows {
            let prefix = session.map { "set \"HC_SESSION=\(shellQuoteInner($0))\" && " } ?? ""
            // cmd launches the native executable with the SSH channel's raw stdin/stdout.
            // Routing the protocol through a PowerShell pipeline corrupts binary frames.
            let installed = #"%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe"#
            return "cmd.exe /d /s /c \"\(prefix)if exist \"\(installed)\" (\"\(installed)\" connect) else (herdr-core.exe connect)\""
        }
        let sessionPrefix = session.map { "HC_SESSION=\(shellQuoteInner($0)) " } ?? ""
        return "sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; "
            + "[ -x \"$p\" ] || { echo \"\(notInstalledMessage)\" >&2; exit 127; }; "
            + "\(sessionPrefix)exec \"$p\" connect'"
    }

    public static let notInstalledMessage = "herdr-core is not installed here"

    /// Session names are restricted by herdr-core, but stay safe inside the outer single quotes anyway.
    private static func shellQuoteInner(_ value: String) -> String {
        value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

#if os(macOS)
/// Runs `herdr-core connect` locally. For tests and a future macOS build.
public final class ProcessTransport: ByteTransport, @unchecked Sendable {
    public let incoming: AsyncThrowingStream<Data, Error>
    private let process: Process
    private let stdin: FileHandle

    public init(executable: URL, arguments: [String] = ["connect"], environment: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        try process.run()
        self.process = process
        self.stdin = input.fileHandleForWriting
        self.incoming = stream
    }

    public func send(_ data: Data) async throws {
        try stdin.write(contentsOf: data)
    }

    public func close() {
        try? stdin.close()
        if process.isRunning { process.terminate() }
    }
}
#endif
