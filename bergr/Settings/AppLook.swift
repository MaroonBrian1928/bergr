import SwiftUI

/// An app-wide look that comes with a pair of terminal themes: a background gradient behind the
/// chat and lists, the chat's colors, translucent rows, and optionally an alternate app icon.
/// Picking its light theme turns on its light style in light mode, its dark theme its dark style
/// in dark mode; every other theme is drawn exactly as without looks. To add one: an entry in
/// `all`, the terminal colors in scripts/themes.py, and optionally an icon set (see AGENTS.md).
struct AppLook: Identifiable, Hashable {
    let id: String
    let name: String
    /// The terminal themes (themes.json ids) it pairs with; nil leaves that appearance alone.
    let lightTheme: String?
    let darkTheme: String?
    let light: LookStyle?
    let dark: LookStyle?
    /// An alternate icon set in the asset catalog (also listed in the project's
    /// ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES), offered in Settings under `name`.
    var iconName: String?

    static func == (a: AppLook, b: AppLook) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Every look. Adding one here is all the app needs.
    static let all: [AppLook] = [miami]

    static func find(_ id: String) -> AppLook? { all.first { $0.id == id } }

    /// The style in use: in light mode the look whose light theme is selected, in dark mode the
    /// one whose dark theme is.
    static func active(lightTheme: String, darkTheme: String, scheme: ColorScheme) -> LookStyle? {
        scheme == .dark
            ? all.first { $0.darkTheme == darkTheme }?.dark
            : all.first { $0.lightTheme == lightTheme }?.light
    }

    fileprivate static func rgb(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(red: Double(hex >> 16 & 0xff) / 255, green: Double(hex >> 8 & 0xff) / 255,
              blue: Double(hex & 0xff) / 255, opacity: opacity)
    }

    /// Dark, a sunset: deep indigo, plum, then a warm brown-amber; lavender secondary text, pink
    /// code and accent. Light, a pastel sunrise: lavender, pink, peach, with plum text and a deep
    /// pink accent (6.8:1 under white text, 5.2:1 or more as text on the gradient).
    static let miami = AppLook(
        id: "miami", name: "Miami", lightTheme: "miami-light", darkTheme: "miami",
        light: LookStyle(
            lookID: "miami", isDark: false,
            gradient: [.init(color: rgb(0xe9dcff), location: 0), .init(color: rgb(0xffd6ea), location: 0.55),
                       .init(color: rgb(0xffe2c8), location: 1)],
            solid: rgb(0xfff4f6), card: .white.opacity(0.62),
            text: rgb(0x2a1033), secondary: rgb(0x674a70), codeText: rgb(0xa3195b),
            codeBackground: .white.opacity(0.6), bubble: .white.opacity(0.7), field: .white.opacity(0.66),
            border: rgb(0x2a1033, 0.14), accent: rgb(0xb0125a), onAccent: .white),
        dark: LookStyle(
            lookID: "miami", isDark: true,
            gradient: [.init(color: rgb(0x1e0b3a), location: 0), .init(color: rgb(0x2e0f45), location: 0.35),
                       .init(color: rgb(0x3a1238), location: 0.65), .init(color: rgb(0x5a3a1a), location: 1)],
            solid: rgb(0x22102e), card: .white.opacity(0.08),
            text: Color(white: 0.97), secondary: rgb(0xc7b8db), codeText: rgb(0xff99d6),
            codeBackground: .white.opacity(0.09), bubble: .white.opacity(0.12), field: .white.opacity(0.08),
            border: .white.opacity(0.16), accent: rgb(0xff6fb5), onAccent: rgb(0x290d33)),
        iconName: "AppIcon-Miami")
}

/// One appearance of a look: what the views draw.
struct LookStyle: Equatable {
    let lookID: String
    let isDark: Bool
    /// Top-left to bottom-right unless set otherwise; text in `text` must read anywhere on it.
    let gradient: [Gradient.Stop]
    var start: UnitPoint = .topLeading
    var end: UnitPoint = .bottomTrailing
    /// One opaque color where something needs it (a header's backdrop); best the terminal's background.
    let solid: Color
    /// Cards and rows on the gradient.
    let card: Color
    let text, secondary, codeText, codeBackground, bubble, field, border, accent, onAccent: Color

    var linearGradient: LinearGradient { LinearGradient(stops: gradient, startPoint: start, endPoint: end) }

    static func == (a: LookStyle, b: LookStyle) -> Bool { a.lookID == b.lookID && a.isDark == b.isDark }

    /// By the palette's style, for `ChatPalette.of(style:)`.
    static func find(_ id: String, dark: Bool) -> LookStyle? {
        AppLook.find(id).flatMap { dark ? $0.dark : $0.light }
    }
}

/// The look style in use, or nil. Reads the stored themes and the color scheme, so a view holding
/// it redraws when any changes.
@propertyWrapper
struct ActiveLook: DynamicProperty {
    @AppStorage(TerminalTheme.lightKey) private var lightTheme = TerminalTheme.defaultLight
    @AppStorage(TerminalTheme.darkKey) private var darkTheme = TerminalTheme.defaultDark
    @Environment(\.colorScheme) private var scheme

    init() {}

    var wrappedValue: LookStyle? { AppLook.active(lightTheme: lightTheme, darkTheme: darkTheme, scheme: scheme) }
}

/// The look's gradient, edge to edge.
struct LookBackground: View {
    let look: LookStyle
    var body: some View { look.linearGradient.ignoresSafeArea() }
}

private struct LookBackdrop: ViewModifier {
    @ActiveLook private var look

    func body(content: Content) -> some View {
        // Modifiers rather than an if/else, so a change of look keeps the view (and its scroll position).
        content
            .scrollContentBackground(look == nil ? .automatic : .hidden)
            .background { if let look { LookBackground(look: look) } }
    }
}

private struct LookRows: ViewModifier {
    @ActiveLook private var look

    func body(content: Content) -> some View {
        content.listRowBackground(look?.card)
    }
}

/// A list section whose header sits on the look's gradient: the plain list's pinned headers
/// draw an opaque band over it, so under a look the header is the section's first row instead.
/// A plain `Section` otherwise.
struct LookSection<Content: View, Header: View>: View {
    @ActiveLook private var look
    @ViewBuilder let content: Content
    @ViewBuilder let header: Header

    var body: some View {
        if look != nil {
            Section {
                header
                    .padding(.top, 12)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .accessibilityAddTraits(.isHeader)
                    .selectionDisabled()
                content
            }
        } else {
            Section { content } header: { header }
        }
    }
}

extension View {
    /// The active look's gradient behind a list, form or scroll view; nothing without a look.
    func lookBackground() -> some View { modifier(LookBackdrop()) }
    /// Translucent rows on the look's gradient (on a row, section or group); the system's otherwise.
    func lookRows() -> some View { modifier(LookRows()) }
}

#if os(iOS)
/// The Home Screen icon: Bergr's own (nil) or a look's alternate one.
enum AppIconChoice {
    /// Every alternate icon the looks bring, with its name.
    static var options: [(name: String, title: String)] {
        AppLook.all.compactMap { look in look.iconName.map { ($0, look.name) } }
    }

    static var current: String? { UIApplication.shared.alternateIconName }
}
#endif
