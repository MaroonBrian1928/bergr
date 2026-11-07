import Testing
import UIKit
@testable import bergr

struct AttachmentsTests {
    private func image(_ w: CGFloat, _ h: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
    }

    @Test func scalesDownLongerSide() throws {
        let data = try #require(AttachmentPrep.jpeg(from: image(4000, 1000)))
        let decoded = try #require(UIImage(data: data))
        let longer = max(decoded.size.width, decoded.size.height) * decoded.scale
        #expect(longer <= 2048)
        #expect(longer > 2000)
        #expect(data.prefix(2) == Data([0xFF, 0xD8]))
    }

    @Test func neverUpscales() throws {
        let data = try #require(AttachmentPrep.jpeg(from: image(300, 200)))
        let decoded = try #require(UIImage(data: data))
        #expect(decoded.size.width * decoded.scale == 300)
        #expect(decoded.size.height * decoded.scale == 200)
    }

    @Test func quotesPathWithSpace() {
        let command = AttachmentPrep.uploadCommand(path: "/tmp/my dir/a.jpg")
        #expect(command.hasSuffix(" '/tmp/my dir/a.jpg'"))
    }

    @Test func quotesPathWithSingleQuote() {
        let command = AttachmentPrep.uploadCommand(path: "/tmp/it's.jpg")
        #expect(command.hasSuffix(" '/tmp/it'\\''s.jpg'"))
    }

    @Test func programHasNoStraySingleQuotes() {
        let command = AttachmentPrep.uploadCommand(path: "/tmp/x.jpg")
        #expect(command.filter { $0 == "'" }.count == 4)
        #expect(command.hasPrefix("python3 -I -c '"))
    }
}
