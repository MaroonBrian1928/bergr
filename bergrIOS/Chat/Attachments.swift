import PhotosUI
import SwiftUI
import UIKit

/// A "+" button: Photo Library, Take Photo, Scan Document or Paste Image.
struct AttachButton: View {
    @Binding var attachments: [ChatAttachment]
    let palette: ChatPalette
    let enabled: Bool

    @State private var picking = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var shooting = false
    @State private var scanning = false

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
            if CameraAvailability.canTakePhoto {
                Button { shooting = true } label: { Label("Take Photo", systemImage: "camera") }
                    .disabled(room <= 0)
            }
            if CameraAvailability.canScan {
                Button { scanning = true } label: { Label("Scan Document", systemImage: "doc.viewfinder") }
                    .disabled(room <= 0)
            }
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
        .fullScreenCover(isPresented: $shooting) {
            CameraPicker(
                onImage: { image in shooting = false; add([image]) },
                onCancel: { shooting = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $scanning) {
            DocumentScanner(
                onScan: { images in scanning = false; add(images) },
                onCancel: { scanning = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            picked = []
            Task { await load(items) }
        }
    }

    private func add(_ images: [UIImage]) {
        attachments.append(contentsOf: ChatAttachment.make(fromCaptured: images, existing: attachments.count))
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
