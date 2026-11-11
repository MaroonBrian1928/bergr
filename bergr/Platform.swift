import HerdrKit
import SwiftUI

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#else
import AppKit
typealias PlatformImage = NSImage
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#endif

// Shims for the few places where iOS and macOS differ in shared views, so those views carry no `#if`.

extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

extension PlatformImage {
    /// JPEG data at `quality` (0...1), or nil if it can't be encoded.
    func jpegData(quality: CGFloat) -> Data? {
        #if os(iOS)
        return jpegData(compressionQuality: quality)
        #else
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: quality])
        #endif
    }

    /// PNG data, or nil if it can't be encoded.
    func pngEncoded() -> Data? {
        #if os(iOS)
        return pngData()
        #else
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
        #endif
    }

    /// Redrawn opaque at `size` points with pixel scale 1 (so points are pixels); bakes in orientation.
    func redrawn(size target: CGSize) -> PlatformImage? {
        #if os(iOS)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        #else
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        CGRect(origin: .zero, size: target).fill()
        draw(in: CGRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: target)
        out.addRepresentation(rep)
        return out
        #endif
    }
}

extension PlatformImage {
    nonisolated static func make(cgImage: CGImage) -> PlatformImage {
        #if os(iOS)
        UIImage(cgImage: cgImage)
        #else
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }
}

/// The system pasteboard.
enum Pasteboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    static var string: String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    static var hasImage: Bool {
        #if os(iOS)
        UIPasteboard.general.hasImages
        #else
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #endif
    }

    static var image: PlatformImage? {
        #if os(iOS)
        UIPasteboard.general.image
        #else
        (NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first
        #endif
    }
}

extension Color {
    /// The screen background (`systemBackground`).
    static var systemBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// The grouped-list background (`systemGroupedBackground`).
    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }
}

extension View {
    /// A full-screen cover on iOS, a sheet on the Mac.
    func platformCover<Content: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    func platformCover<Item: Identifiable, Content: View>(item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(item: item, content: content)
        #else
        sheet(item: item, content: content)
        #endif
    }

    /// `navigationBarTitleDisplayMode(.inline)`; no-op on the Mac.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.never)`; no-op on the Mac.
    func noAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// `textInputAutocapitalization(.words)`; no-op on the Mac.
    func wordsAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.words)
        #else
        self
        #endif
    }

    /// `keyboardType(.numberPad)`; no-op on the Mac.
    func numberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    /// `keyboardType(.URL)`; no-op on the Mac.
    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }
}

extension PlatformColor {
    convenience init(_ rgb: RGB) {
        self.init(red: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }
}

extension ToolbarItemPlacement {
    /// `.topBarLeading` on iOS, `.navigation` on the Mac.
    static var leadingAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }

    /// `.topBarTrailing` on iOS, `.primaryAction` on the Mac.
    static var trailingAction: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }
}

enum DeviceName {
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    static var current: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Foundation.Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
    }
}

/// Compact pointer controls on Mac; retain touch targets on iOS.
enum PlatformMetrics {
    #if os(macOS)
    static let controlHeight: CGFloat = 28
    static let sendButtonSize: CGFloat = 26
    #else
    static let controlHeight: CGFloat = 44
    static let sendButtonSize: CGFloat = 34
    #endif
}

extension View {
    func macPlainButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}
