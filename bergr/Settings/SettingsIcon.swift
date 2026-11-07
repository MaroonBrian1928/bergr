import SwiftUI

/// A Settings-app style icon: a white SF Symbol on a tinted rounded square.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    init(_ systemName: String, color: Color) {
        self.systemName = systemName
        self.color = color
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 29, height: 29)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Tints toggles, buttons and links with the chat's coral.
private struct BergrTint: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.tint(ChatPalette.of(scheme).accent)
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

    var body: some View {
        Label {
            Text(title).foregroundStyle(ChatPalette.of(scheme).accent)
        } icon: {
            SettingsIcon(systemImage, color: ChatPalette.of(scheme).accent)
        }
        .frame(minHeight: 44)
    }
}
