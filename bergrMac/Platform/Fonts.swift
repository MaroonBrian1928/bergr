import AppKit
import SwiftUI

/// Mac twin of the iOS `Fonts` (in `bergrIOS/Screen/TerminalCanvas.swift`), only as much as shared
/// Settings needs: the terminal font's regular face for the preview.
struct Fonts {
    let size: CGFloat
    let family: TerminalFont
    let regular: NSFont

    init(size: CGFloat, family: TerminalFont = .jetBrainsMono) {
        self.size = size
        self.family = family
        Self.registered()
        regular = family.names[0].flatMap { NSFont(name: $0, size: size) }
            ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var regularFont: Font { Font(regular as CTFont) }

    private static func registered() { _ = registeredOnce }
    private static let registeredOnce: Bool = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()
}
