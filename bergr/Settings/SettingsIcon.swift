import SwiftUI

/// A Settings-app style icon: a white SF Symbol on a tinted rounded square.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    /// The symbol's box: about 60% of the 29 pt tile, Apple's Settings proportion.
    static let glyph: CGFloat = 18

    init(_ systemName: String, color: Color) {
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        // Fitted into a fixed box inside the tile, so a wide or tall symbol (three connected
        // points, a phone with waves) keeps the same margin as a round one instead of reaching the edge.
        Image(systemName: systemName)
            .resizable()
            .symbolRenderingMode(.monochrome)
            .fontWeight(.semibold)
            .scaledToFit()
            .frame(width: Self.glyph, height: Self.glyph)
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Tints toggles, buttons and links with the chat's coral.
private struct BergrTint: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @ActiveLook private var look
    func body(content: Content) -> some View {
        content.tint(ChatPalette.of(scheme, look: look).accent)
    }
}

extension View {
    /// The app's accent (the chat's coral) for primary actions and toggles.
    func bergrTint() -> some View { modifier(BergrTint()) }
}

/// An accent-colored action row: a plus tile and a title.
struct AccentLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.colorScheme) private var scheme
    @ActiveLook private var look

    var body: some View {
        let accent = ChatPalette.of(scheme, look: look).accent
        Label {
            Text(title).foregroundStyle(accent)
        } icon: {
            SettingsIcon(systemImage, color: accent)
        }
        .frame(minHeight: 44)
    }
}
