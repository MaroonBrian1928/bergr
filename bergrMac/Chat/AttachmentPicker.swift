import SwiftUI
import UniformTypeIdentifiers

/// Choosing image files to attach, and turning files into attachments.
@MainActor
enum AttachmentPicker {
    /// Shows an open panel for images; at most `limit` attachments come back.
    static func pick(limit: Int) async -> [ChatAttachment] {
        guard limit > 0 else { return [] }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to attach"
        panel.prompt = "Attach"
        let response: NSApplication.ModalResponse = await withCheckedContinuation { cont in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { cont.resume(returning: $0) }
            } else {
                panel.begin { cont.resume(returning: $0) }
            }
        }
        guard response == .OK else { return [] }
        return attachments(from: panel.urls, limit: limit)
    }

    /// Image files among `urls`, as attachments (non-images and unreadable files are skipped).
    static func attachments(from urls: [URL], limit: Int) -> [ChatAttachment] {
        let images = urls.compactMap { url -> NSImage? in
            guard isImageFile(url) else { return nil }
            return NSImage(contentsOf: url)
        }
        return images.prefix(max(0, limit)).compactMap { ChatAttachment.make(from: $0) }
    }

    static func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
    }
}

/// What a paste or drop carries, decided apart from the view.
enum ComposerPasteboard {
    /// Images to attach from a pasteboard, or `[]` when the paste should go through as text:
    /// anything with a string on it stays text (rich text copied from a page carries an image too),
    /// unless it is an image file copied in Finder.
    static func images(from pasteboard: NSPasteboard) -> [NSImage] {
        if pasteboard.string(forType: .string) != nil, !hasImageFile(pasteboard) { return [] }
        return (pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage]) ?? []
    }

    static func hasImageFile(_ pasteboard: NSPasteboard) -> Bool {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains(where: AttachmentPicker.isImageFile)
    }
}

/// The chat's "+" button. Same name and call shape as the iOS twin in `bergrIOS/Chat/Attachments.swift`.
struct AttachButton: View {
    @Binding var attachments: [ChatAttachment]
    let palette: ChatPalette
    let enabled: Bool

    init(attachments: Binding<[ChatAttachment]>, palette: ChatPalette, enabled: Bool) {
        _attachments = attachments
        self.palette = palette
        self.enabled = enabled
    }

    var body: some View {
        Menu {
            Button("Choose Image…", systemImage: "photo.on.rectangle") {
                Task {
                    let room = ChatAttachment.limit - attachments.count
                    if room > 0 { attachments += await AttachmentPicker.pick(limit: room).prefix(room) }
                }
            }
            Button("Paste Image", systemImage: "doc.on.clipboard") {
                if attachments.count < ChatAttachment.limit, let image = Pasteboard.image,
                   let item = ChatAttachment.make(from: image) { attachments.append(item) }
            }
            .disabled(!Pasteboard.hasImage)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.medium))
                .foregroundStyle(palette.secondary)
                .frame(width: PlatformMetrics.controlHeight, height: PlatformMetrics.controlHeight)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // One glyph, like the send button: the menu's own chevron beside it read as a second control.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Attach Image")
        .disabled(!enabled)
        .accessibilityLabel("Attach image")
    }
}
