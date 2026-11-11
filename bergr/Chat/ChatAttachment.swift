import Foundation
import SwiftUI

/// An image picked for a chat reply, ready to upload.
struct ChatAttachment: Identifiable, Equatable {
    let id: UUID
    let thumbnail: PlatformImage
    /// JPEG.
    let data: Data

    static func == (a: ChatAttachment, b: ChatAttachment) -> Bool { a.id == b.id }

    static let limit = 4

    /// Builds an attachment from an image, or nil if it can't be encoded.
    static func make(from image: PlatformImage) -> ChatAttachment? {
        guard let data = AttachmentPrep.jpeg(from: image),
              let thumb = AttachmentPrep.thumbnail(from: image) else { return nil }
        return ChatAttachment(id: UUID(), thumbnail: thumb, data: data)
    }
}

enum AttachmentPrep {
    /// JPEG, scaled down so the longer side is at most `maxDimension` pixels (never up), at `quality`.
    static func jpeg(from image: PlatformImage, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        scaled(image, maxDimension: maxDimension)?.jpegData(quality: quality)
    }

    static func thumbnail(from image: PlatformImage) -> PlatformImage? {
        scaled(image, maxDimension: 224)
    }

    /// Redraws at pixel scale 1 so `maxDimension` is in pixels, and bakes in orientation.
    private static func scaled(_ image: PlatformImage, maxDimension: CGFloat) -> PlatformImage? {
        let size = image.size
        let longer = max(size.width, size.height)
        let ratio = longer > maxDimension ? maxDimension / longer : 1
        let target = CGSize(width: max(1, (size.width * ratio).rounded()), height: max(1, (size.height * ratio).rounded()))
        return image.redrawn(size: target)
    }

    /// The remote command that reads one base64 line on stdin, writes it to `path` (creating the directory), prints the path.
    static func uploadCommand(path: String) -> String {
        // The program holds no single quotes, so it sits safely inside them.
        let program = "import base64,os,sys;p=sys.argv[1];os.makedirs(os.path.dirname(p),exist_ok=True);"
            + "open(p,\"wb\").write(base64.b64decode(sys.stdin.readline()));print(p,flush=True)"
        return "python3 -I -c '\(program)' \(shellQuote(path))"
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Thumbnails of the attached images, each removable.
struct AttachmentStrip: View {
    @Binding var attachments: [ChatAttachment]
    let palette: ChatPalette

    init(attachments: Binding<[ChatAttachment]>, palette: ChatPalette) {
        _attachments = attachments
        self.palette = palette
    }

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { item in
                        Image(platformImage: item.thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(palette.border))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    attachments.removeAll { $0.id == item.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Color.black.opacity(0.65), in: Circle())
                                        .frame(width: 32, height: 32)
                                        .contentShape(Rectangle())
                                }
                                .offset(x: 8, y: -8)
                                .accessibilityLabel("Remove image")
                            }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }
        }
    }
}
