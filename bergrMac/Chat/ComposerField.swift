import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What a key press in the composer does. Pure, so it is testable.
enum ComposerKeyAction: Equatable {
    case send, newline, passThrough

    /// `selector` is the text system's command for the key; `shift`/`option`/`command` are the modifiers held.
    /// Return sends; Shift- or Option-Return breaks the line; Command-Return is left to the window
    /// (the chat's own ⌘↩ send shortcut). Composition (IME) Return never gets here: the input method eats it.
    static func decide(selector: Selector, shift: Bool, option: Bool, command: Bool) -> ComposerKeyAction {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if command { return .passThrough }
            return shift || option ? .newline : .send
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            return .newline
        default:
            return .passThrough
        }
    }
}

/// The chat's reply box on the Mac: SwiftUI's own multi-line text field, which draws, focuses and
/// edits like any Mac text field. Return sends, Shift- or Option-Return breaks the line, ⌘↩ is left
/// to the chat's send shortcut. Images on the clipboard (⌘V) or dropped on it are attached.
/// Same call shape as the iOS twin.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var textColor: PlatformColor
    var placeholderColor: PlatformColor
    var enabled = true
    var maxLines = 6
    var onSubmit: (() -> Void)?
    var onPasteImages: ([PlatformImage]) -> Void

    init(text: Binding<String>, placeholder: String, textColor: PlatformColor, placeholderColor: PlatformColor,
         enabled: Bool = true, maxLines: Int = 6, onSubmit: (() -> Void)? = nil,
         onPasteImages: @escaping ([PlatformImage]) -> Void) {
        _text = text
        self.placeholder = placeholder
        self.textColor = textColor
        self.placeholderColor = placeholderColor
        self.enabled = enabled
        self.maxLines = maxLines
        self.onSubmit = onSubmit
        self.onPasteImages = onPasteImages
    }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...maxLines)
            .disabled(!enabled)
            .accessibilityIdentifier("reply-field")
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.command) { return .ignored }
                if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                    text += "\n"
                    return .handled
                }
                onSubmit?()
                return .handled
            }
            // Only when the clipboard holds an image or an image file: text pastes as usual.
            .onPasteCommand(of: [.image, .png, .tiff, .fileURL]) { _ in
                let images = ComposerPasteboard.images(from: .general)
                if !images.isEmpty { onPasteImages(images) }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { _ in
                let images = ComposerPasteboard.images(from: NSPasteboard(name: .drag))
                guard !images.isEmpty else { return false }
                onPasteImages(images)
                return true
            }
    }
}
