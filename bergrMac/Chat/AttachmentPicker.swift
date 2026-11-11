import SwiftUI

/// Stub (chunk C): choosing files to attach. Fill in with `NSOpenPanel` and return the attachments.
@MainActor
enum AttachmentPicker {
    static func pick(limit: Int) async -> [ChatAttachment] { [] }
}

/// The chat's "+" button. Same name and call shape as the iOS twin in `bergrIOS/Chat/Attachments.swift`.
/// Stub (chunk C): attaches nothing yet except an image on the pasteboard.
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
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!enabled)
        .accessibilityLabel("Attach image")
    }
}
