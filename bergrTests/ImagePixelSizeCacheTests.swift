import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import bergr

@MainActor
struct ImagePixelSizeCacheTests {
    /// A solid PNG of the given pixel size.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return out as Data
    }

    @Test func pixelSizeMatchesTheImage() throws {
        let cache = PixelSizeCache(read: ImageThumbs.readPixelSize)
        #expect(cache.size(of: try makePNG(width: 40, height: 30)) == CGSize(width: 40, height: 30))
        #expect(cache.size(of: try makePNG(width: 7, height: 90)) == CGSize(width: 7, height: 90))
    }

    @Test func readsEachImageOnce() throws {
        let cache = PixelSizeCache(read: ImageThumbs.readPixelSize)
        let png = try makePNG(width: 40, height: 30)
        for _ in 0..<5 {
            #expect(cache.size(of: png) == CGSize(width: 40, height: 30))
        }
        #expect(cache.reads == 1)

        let other = try makePNG(width: 10, height: 20)
        #expect(cache.size(of: other) == CGSize(width: 10, height: 20))
        #expect(cache.reads == 2)
    }

    @Test func notAnImageIsReadOnceAndReportsNil() {
        let cache = PixelSizeCache(read: ImageThumbs.readPixelSize)
        let junk = Data("not an image".utf8)
        #expect(cache.size(of: junk) == nil)
        #expect(cache.size(of: junk) == nil)
        #expect(cache.reads == 1)
    }

    @Test func sharedCacheReturnsTheSameSize() throws {
        let png = try makePNG(width: 12, height: 34)
        #expect(ImageThumbs.pixelSize(png) == CGSize(width: 12, height: 34))
        #expect(ImageThumbs.pixelSize(png) == CGSize(width: 12, height: 34))
    }
}
