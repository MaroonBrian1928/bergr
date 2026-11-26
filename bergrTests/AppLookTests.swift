import SwiftUI
import Testing
@testable import bergr

struct AppLookTests {
    @Test func aLookTurnsOnWithItsThemeForThatScheme() {
        let light = TerminalTheme.defaultLight, dark = TerminalTheme.defaultDark
        #expect(AppLook.active(lightTheme: light, darkTheme: "miami", scheme: .dark) == AppLook.miami.dark)
        #expect(AppLook.active(lightTheme: light, darkTheme: "miami", scheme: .light) == nil)
        #expect(AppLook.active(lightTheme: "miami-light", darkTheme: dark, scheme: .light) == AppLook.miami.light)
        #expect(AppLook.active(lightTheme: "miami-light", darkTheme: dark, scheme: .dark) == nil)
        #expect(AppLook.active(lightTheme: light, darkTheme: "dracula", scheme: .dark) == nil)
    }

    @Test func paletteStyleFollowsSchemeAndLook() {
        #expect(ChatPalette.of(.light).style == .light)
        #expect(ChatPalette.of(.dark).style == .dark)
        #expect(ChatPalette.of(.dark, look: AppLook.miami.dark).style == .look("miami", dark: true))
        #expect(ChatPalette.of(.light, look: AppLook.miami.light).style == .look("miami", dark: false))
        #expect(!ChatPalette.of(.light, look: AppLook.miami.light).isDark)
        // A style for the other scheme doesn't apply.
        #expect(ChatPalette.of(.light, look: AppLook.miami.dark).style == .light)
        #expect(ChatPalette.of(style: .look("nope", dark: true)).style == .dark)
    }

    /// Every look's themes exist, on the right side, with full palettes.
    @Test func everyLookHasItsTerminalThemes() throws {
        let hex = /#[0-9a-f]{6}/
        for look in AppLook.all {
            for (id, dark) in [(look.lightTheme, false), (look.darkTheme, true)] {
                guard let id else { continue }
                let theme = try #require(TerminalTheme.all.first { $0.id == id && $0.dark == dark }, "\(id)")
                #expect(theme.ansi.count == 16)
                for color in theme.ansi + [theme.background, theme.foreground, theme.cursor, theme.selection] {
                    #expect(color.wholeMatch(of: hex) != nil, "\(id): \(color)")
                }
            }
            #expect((look.lightTheme == nil) == (look.light == nil))
            #expect((look.darkTheme == nil) == (look.dark == nil))
        }
    }

    /// WCAG contrast: text on the accent, and the accent and text as text on every gradient stop.
    @Test func lookColorsMeetContrast() throws {
        for look in AppLook.all {
            for style in [look.light, look.dark].compactMap({ $0 }) {
                #expect(Self.contrast(style.onAccent, style.accent) >= 4.5, "\(look.id) onAccent \(Self.contrast(style.onAccent, style.accent))")
                for stop in style.gradient {
                    #expect(Self.contrast(style.text, stop.color) >= 7, "\(look.id) text \(Self.contrast(style.text, stop.color))")
                    #expect(Self.contrast(style.secondary, stop.color) >= 4.5, "\(look.id) secondary \(Self.contrast(style.secondary, stop.color))")
                    if !style.isDark { #expect(Self.contrast(style.accent, stop.color) >= 4.5, "\(look.id) accent \(Self.contrast(style.accent, stop.color))") }
                }
            }
        }
    }

    @Test func announcesOnceAndNotOnFreshInstalls() {
        #expect(LookAnnouncement.shouldShow(announced: false, hasMachines: true))
        #expect(!LookAnnouncement.shouldShow(announced: true, hasMachines: true))
        #expect(!LookAnnouncement.shouldShow(announced: false, hasMachines: false))
    }

    static func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let r = color.resolve(in: EnvironmentValues())
            func channel(_ v: Float) -> Double {
                let v = Double(v)
                return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r.red) + 0.7152 * channel(r.green) + 0.0722 * channel(r.blue)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
