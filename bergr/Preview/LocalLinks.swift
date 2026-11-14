import Foundation
import TerminalCore

/// Addresses of pages on the agent's machine (`localhost:3000`) in chat text, made links that open
/// the preview (see `LocalPreviewSheet`).
enum LocalLinks {
    /// Links each local address in `text`, leaving ranges that already link elsewhere.
    static func link(_ text: inout AttributedString) {
        let plain = String(text.characters)
        for match in LocalWebAddress.matches(in: plain) {
            let lo = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: match.range.lowerBound))
            let hi = text.characters.index(text.startIndex, offsetBy: plain.distance(from: plain.startIndex, to: match.range.upperBound))
            if text[lo..<hi].runs.contains(where: { $0.link != nil }) { continue }
            text[lo..<hi].link = match.address.url
        }
    }
}

/// A preview to show, for `.sheet(item:)`.
struct PreviewItem: Identifiable {
    let id = UUID()
    let address: LocalWebAddress
}

extension Notification.Name {
    /// A terminal asks its screen to preview a local page. The object is the terminal's model,
    /// `userInfo["address"]` the `LocalWebAddress`.
    static let openLocalPreview = Notification.Name("bergr.openLocalPreview")
}
