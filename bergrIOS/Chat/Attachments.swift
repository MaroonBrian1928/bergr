import PhotosUI
import SwiftUI
import UIKit

/// A "+" button: Photo Library or Paste Image.
struct AttachButton: View {
    @Binding var attachments: [ChatAttachment]
    let palette: ChatPalette
    let enabled: Bool

    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []

    init(attachments: Binding<[ChatAttachment]>, palette: ChatPalette, enabled: Bool) {
        _attachments = attachments
        self.palette = palette
        self.enabled = enabled
    }

    private var room: Int { ChatAttachment.limit - attachments.count }

    var body: some View {
        Menu {
            Button { picking = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                .disabled(room <= 0)
            Button(action: paste) { Label("Paste Image", systemImage: "doc.on.clipboard") }
                .disabled(room <= 0 || !UIPasteboard.general.hasImages)
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(palette.text)
                .frame(width: 34, height: 34)
                .background(palette.bubble, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .disabled(!enabled)
        .accessibilityLabel("Attach image")
        .photosPicker(isPresented: $picking, selection: $picked, maxSelectionCount: max(1, room), matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await load(items) }
        }
    }

    private func paste() {
        guard let image = UIPasteboard.general.image, room > 0, let item = ChatAttachment.make(from: image) else { return }
        attachments.append(item)
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard attachments.count < ChatAttachment.limit,
                  let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let attachment = ChatAttachment.make(from: image) else { continue }
            attachments.append(attachment)
        }
    }
}
