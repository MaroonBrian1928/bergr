import Testing
import UIKit
@testable import bergr

struct CapturedAttachmentsTests {
    private func image(_ w: CGFloat, _ h: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    @Test func scanPagesStopAtLimit() {
        let pages = (0..<6).map { _ in image(100, 100) }
        #expect(ChatAttachment.make(fromCaptured: pages, existing: 0).count == ChatAttachment.limit)
        #expect(ChatAttachment.make(fromCaptured: pages, existing: 3).count == 1)
        #expect(ChatAttachment.make(fromCaptured: pages, existing: ChatAttachment.limit).isEmpty)
    }

    @Test func capturedImagesAreDownscaledLikePickedPhotos() throws {
        let item = try #require(ChatAttachment.make(fromCaptured: [image(4000, 3000)], existing: 0).first)
        let decoded = try #require(UIImage(data: item.data))
        #expect(max(decoded.size.width, decoded.size.height) * decoded.scale <= 2048)
    }
}
