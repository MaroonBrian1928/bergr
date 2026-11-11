import Foundation
import SSHTransport
import SwiftUI

/// Images sent from the chat travel to the agent as file paths on the machine
/// (`/tmp/bergr-images/<uuid>.jpg`, see `HostSession.uploadImage`), so the conversation records
/// the path, not the picture. This shows those messages as the pictures again: from the copy
/// kept when sending, else read back from the machine.
enum SentImages {
    /// A path Bergr uploaded, anywhere in a message.
    static let pattern = /\/tmp\/bergr-images\/[0-9a-f-]{36}\.jpg/

    /// The image paths in a message, and its words without them.
    static func split(_ text: String) -> (paths: [String], text: String) {
        let paths = text.matches(of: pattern).map { String($0.output) }
        guard !paths.isEmpty else { return ([], text) }
        let rest = text.replacing(pattern, with: "")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (paths, rest)
    }

    private static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "sent-images", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func file(for path: String) -> URL {
        folder.appending(path: (path as NSString).lastPathComponent)
    }

    /// Keeps what was sent, so the message shows it without asking the machine.
    static func store(_ data: Data, for path: String) {
        try? data.write(to: file(for: path), options: .atomic)
    }

    static func cached(_ path: String) -> Data? {
        try? Data(contentsOf: file(for: path))
    }

    /// The image from the cache, or from the machine (and cached). Nil when it's gone there too
    /// (/tmp is cleared on reboot).
    static func load(_ path: String, session: HostSession?) async -> Data? {
        if let data = cached(path) { return data }
        guard let session, session.canRunCommands, path.wholeMatch(of: pattern) != nil else { return nil }
        guard let pipe = try? await session.openExec("base64 < \(path)") else { return nil }
        defer { pipe.close() }
        var out = Data()
        do { for try await chunk in pipe.output { out.append(chunk) } } catch { if out.isEmpty { return nil } }
        let text = String(decoding: out, as: UTF8.self).filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: text), PlatformImage(data: data) != nil else { return nil }
        store(data, for: path)
        return data
    }
}

/// One sent image in a message: the picture once loaded, a placeholder meanwhile or if gone.
struct SentImageView: View {
    let path: String
    let session: HostSession?
    let palette: ChatPalette
    @State private var data: Data?
    @State private var gone = false

    var body: some View {
        Group {
            if let data {
                ImageBubble(data: data, fromUser: true, palette: palette)
            } else {
                Label(gone ? "Image no longer on the machine" : "Image", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(palette.bubble, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .task(id: path) {
            data = SentImages.cached(path)
            guard data == nil else { return }
            data = await SentImages.load(path, session: session)
            gone = data == nil
        }
    }
}
