import Foundation
import HerdrKit
import SSHTransport

/// "This Mac": finds `herdr-core` and talks to it without SSH. Only the Mac build can start a
/// process; on iOS everything here reports "not installed".
enum LocalCore {
    /// Folders to look in besides `PATH`: a Dock-launched app gets a bare `PATH`.
    static func extraFolders(home: URL) -> [String] {
        [home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The `herdr-core` executable: on `PATH` first, then `~/.local/bin` and the Homebrew folders.
    static func locate(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let folders = (path ?? "").split(separator: ":").map(String.init) + extraFolders(home: home)
        for folder in folders where folder.hasPrefix("/") {
            let candidate = folder + "/herdr-core"
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }

    /// `PATH` for local commands: the usual one plus the folders above.
    static func searchPath(
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> String {
        var parts = (path ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        for folder in extraFolders(home: home) where !parts.contains(folder) { parts.append(folder) }
        return parts.joined(separator: ":")
    }

    static var isAvailable: Bool { isMac && locate() != nil }

    static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    /// Same failure the SSH path reports when the core is missing (exit 127), so it is not retried.
    static var notInstalled: Error {
        SSHTransportError.commandFailed(exitCode: 127, stderr: HerdrCore.notInstalledMessage)
    }

    static func connect(session: String?) async throws -> HerdrClient {
        #if os(macOS)
        guard let executable = locate() else { throw notInstalled }
        var environment: [String: String] = ["PATH": searchPath()]
        if let session, !session.isEmpty { environment["HC_SESSION"] = session }
        let transport = try ProcessTransport(executable: executable, environment: environment)
        return try await HerdrClient.connect(over: transport)
        #else
        throw notInstalled
        #endif
    }

    /// Runs a shell command here, like `SSHConnection.openExec` does on a remote machine.
    static func openExec(_ command: String) throws -> ExecPipe {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ProcessInfo.processInfo.environment.merging(["PATH": searchPath()]) { $1 }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    let status = Int(process.terminationStatus)
                    if status == 0 || process.terminationReason == .uncaughtSignal {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: SSHTransportError.commandFailed(exitCode: status, stderr: ""))
                    }
                }
            } else {
                continuation.yield(data)
            }
        }
        try process.run()
        let stdin = input.fileHandleForWriting
        return ExecPipe(
            output: stream,
            write: { try stdin.write(contentsOf: $0) },
            close: {
                try? stdin.close()
                if process.isRunning { process.terminate() }
            })
        #else
        throw notInstalled
        #endif
    }
}
