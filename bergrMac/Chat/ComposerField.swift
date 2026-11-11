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
            // ⌘V with an image (or image file) on the clipboard attaches it; text pastes as usual.
            // The field's own editor handles ⌘V before SwiftUI's paste hooks, so it's caught first.
            .background(ImagePasteCatcher(onPasteImages: onPasteImages).frame(width: 0, height: 0))
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { _ in
                let images = ComposerPasteboard.images(from: NSPasteboard(name: .drag))
                guard !images.isEmpty else { return false }
                onPasteImages(images)
                return true
            }
    }
}

/// Catches ⌘V in this view's window when the clipboard holds images and no text, before the text
/// field's editor takes it (it would paste nothing). One per composer; only its own window counts.
private struct ImagePasteCatcher: NSViewRepresentable {
    let onPasteImages: ([PlatformImage]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator = context.coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
            let images = ComposerPasteboard.images(from: .general)
            guard !images.isEmpty else { return event }
            coordinator.onPasteImages(images)
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onPasteImages = onPasteImages }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPasteImages: onPasteImages) }

    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var onPasteImages: ([PlatformImage]) -> Void
        init(onPasteImages: @escaping ([PlatformImage]) -> Void) { self.onPasteImages = onPasteImages }
    }
}
