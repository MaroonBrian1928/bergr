import Foundation
import SSHTransport

extension HostSession {
    /// Uploads JPEG data to `/tmp/bergr-images/<uuid>.jpg` on the machine (tmp is cleared on reboot)
    /// and returns that path. Throws on failure or if no line comes back within 20 s.
    func uploadImage(_ data: Data) async throws -> String {
        let path = "/tmp/bergr-images/\(UUID().uuidString.lowercased()).jpg"
        let pipe = try await openExec(AttachmentPrep.uploadCommand(path: path))
        defer { pipe.close() }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await pipe.write(Data((data.base64EncodedString() + "\n").utf8))
                var buffer = Data()
                for try await chunk in pipe.output {
                    buffer.append(chunk)
                    if let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[..<newline], as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !line.isEmpty else { break }
                        return line
                    }
                }
                throw UploadError.noReply
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw UploadError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    enum UploadError: LocalizedError {
        case noReply, timedOut
        var errorDescription: String? {
            switch self {
            case .noReply: "The machine didn't confirm the image upload. Try sending the image again."
            case .timedOut: "Uploading the image timed out. Try sending it again."
            }
        }
    }
}
