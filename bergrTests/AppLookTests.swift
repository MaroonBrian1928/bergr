import SwiftUI
import Testing
@testable import bergr

struct AppLookTests {
    @Test func aLookOnlyInDarkModeWithItsTheme() {
        #expect(AppLook.active(darkTheme: "miami", scheme: .dark) == .miami)
        #expect(AppLook.active(darkTheme: "miami", scheme: .light) == nil)
        #expect(AppLook.active(darkTheme: TerminalTheme.defaultDark, scheme: .dark) == nil)
        #expect(AppLook.active(darkTheme: "dracula", scheme: .dark) == nil)
    }

    @Test func paletteStyleFollowsSchemeAndLook() {
        #expect(ChatPalette.of(.light).style == .light)
        #expect(ChatPalette.of(.dark).style == .dark)
        #expect(ChatPalette.of(.dark, look: .miami).style == .look("miami"))
        // Light mode never changes, whatever the dark theme.
        #expect(ChatPalette.of(.light, look: .miami).style == .light)
        #expect(ChatPalette.of(.dark, look: .miami).isDark)
        // An unknown look falls back to the plain dark palette.
        #expect(ChatPalette.of(style: .look("nope")).style == .dark)
    }

    /// Every look pairs with a dark terminal theme that exists, with a full palette.
    @Test func everyLookHasItsTerminalTheme() throws {
        let hex = /#[0-9a-f]{6}/
        for look in AppLook.all {
            let theme = try #require(TerminalTheme.all.first { $0.id == look.id && $0.dark }, "\(look.id)")
            #expect(theme.ansi.count == 16)
            for color in theme.ansi + [theme.background, theme.foreground, theme.cursor, theme.selection] {
                #expect(color.wholeMatch(of: hex) != nil, "\(look.id): \(color)")
            }
        }
        #expect(TerminalTheme.find("miami", dark: true).name == "Miami")
    }
}
