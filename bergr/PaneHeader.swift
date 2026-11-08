import SwiftUI

/// What a pane draws in place of the system title bar when two conversations sit side by side.
/// (The split view's detail column has one bar for everything in it, and every toolbar in the
/// column lands there, so with two panes each draws its own header.)
struct PaneChrome {
    /// The leading button: the sidebar toggle on the first pane, Close on the second.
    let buttonLabel: String
    let buttonImage: String
    let action: () -> Void
    var title = ""
    var subtitle = ""
    /// Buttons that sit before the chat's own (Show Terminal, ...).
    var extra: AnyView = AnyView(EmptyView())
    var identifier = "pane"
}

/// A compact Liquid Glass header above one pane.
struct PaneHeader<Trailing: View>: View {
    let chrome: PaneChrome
    /// The pane's own background: the header sits on it, so text scrolling up doesn't show through the title.
    var backdrop: Color = Color(uiColor: .systemBackground)
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button(chrome.buttonLabel, systemImage: chrome.buttonImage, action: chrome.action)
                .labelStyle(.iconOnly)
                .frame(width: 40, height: 40)
                .glassEffect(.regular.interactive(), in: Circle())
                .accessibilityIdentifier("\(chrome.identifier).leading")
            VStack(spacing: 0) {
                Text(chrome.title).font(.headline).lineLimit(1)
                    .accessibilityIdentifier("\(chrome.identifier).title")
                if !chrome.subtitle.isEmpty {
                    Text(chrome.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity)
            HStack(spacing: 4) {
                chrome.extra
                trailing
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 6)
            .frame(minHeight: 40)
            .glassEffect(.regular, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            // Solid behind the header, so text scrolling up disappears cleanly under it,
            // with a short fade at its lower edge instead of a hard line.
            VStack(spacing: 0) {
                backdrop
                LinearGradient(colors: [backdrop, backdrop.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 10)
            }
            .padding(.bottom, -10)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}
