import SwiftUI
import AppKit

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

/// The chat's reply box on the Mac: a multi-line `NSTextView`. Return sends, Shift-Return breaks the line,
/// images (and image files) can be pasted or dropped. Same call shape as the iOS twin.
struct ComposerField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var textColor: PlatformColor
    var placeholderColor: PlatformColor
    var enabled = true
    var maxLines = 6
    /// Called directly on plain Return.
    var onSubmit: (() -> Void)?
    var onPasteImages: ([PlatformImage]) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.minSize = NSSize(width: 0, height: textView.lineHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("reply-field")
        textView.registerForDraggedTypes([.fileURL, .tiff, .png])

        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.delegate = context.coordinator
        // The chat's SwiftUI color didn't survive the trip to NSColor (text drew invisibly): use the
        // system's label colors, which follow light and dark mode.
        let textColor = NSColor.labelColor
        view.textColor = textColor
        view.insertionPointColor = textColor
        // New typing takes its look from the typing attributes, not textColor: without them it
        // came out in the default color, white on the light bubble.
        view.typingAttributes = [.foregroundColor: textColor, .font: view.font ?? .preferredFont(forTextStyle: .body)]
        view.placeholder = placeholder
        view.placeholderColor = .placeholderTextColor
        view.isEditable = enabled
        view.isSelectable = enabled
        view.maxLines = maxLines
        view.onPasteImages = { onPasteImages($0) }
        if view.string != text, !view.hasMarkedText() {
            view.string = text
        }
        if let storage = view.textStorage, storage.length > 0, !view.hasMarkedText() {
            storage.addAttribute(.foregroundColor, value: textColor, range: NSRange(location: 0, length: storage.length))
        }
        // The text view spans the whole box, so a click anywhere in it lands in the text.
        let width = scroll.contentSize.width
        if width > 0, abs(view.frame.width - width) > 0.5 {
            view.setFrameSize(NSSize(width: width, height: max(view.frame.height, scroll.contentSize.height)))
        }
        view.needsDisplay = true
        scroll.hasVerticalScroller = view.contentHeight() > view.maxHeight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = scroll.documentView as? ComposerTextView else { return nil }
        let width = proposal.width ?? 300
        view.setFrameSize(NSSize(width: width, height: max(view.frame.height, view.lineHeight)))
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        return CGSize(width: width, height: min(max(view.contentHeight(), view.lineHeight), view.maxHeight))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerField
        init(_ parent: ComposerField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            view.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            switch ComposerKeyAction.decide(selector: selector, shift: flags.contains(.shift),
                                            option: flags.contains(.option), command: flags.contains(.command)) {
            case .passThrough:
                return false
            case .newline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            case .send:
                parent.text = textView.string
                parent.onSubmit?()
                return true
            }
        }
    }
}

final class ComposerTextView: NSTextView {
    var placeholder = ""
    var placeholderColor: NSColor = .placeholderTextColor
    var maxLines = 6
    var onPasteImages: ([NSImage]) -> Void = { _ in }

    var lineHeight: CGFloat {
        let f = font ?? .preferredFont(forTextStyle: .body)
        return ceil(f.ascender - f.descender + f.leading)
    }
    var maxHeight: CGFloat { lineHeight * CGFloat(maxLines) }

    func contentHeight() -> CGFloat {
        guard let layout = layoutManager, let container = textContainer else { return lineHeight }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }

    override func paste(_ sender: Any?) {
        let images = ComposerPasteboard.images(from: .general)
        if images.isEmpty { pasteAsPlainText(sender) } else { onPasteImages(images) }
    }

    // MARK: Drop

    private func droppedImages(_ info: NSDraggingInfo) -> [NSImage] {
        ComposerPasteboard.images(from: info.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImages(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedImages(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = droppedImages(sender)
        guard !images.isEmpty else { return super.performDragOperation(sender) }
        onPasteImages(images)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText() {
            (placeholder as NSString).draw(at: .zero, withAttributes: [
                .font: font ?? NSFont.preferredFont(forTextStyle: .body), .foregroundColor: placeholderColor,
            ])
        }
    }
}

/// Clicks anywhere in the box (the text view can be shorter than the box) put the cursor in it.
final class ComposerScrollView: NSScrollView {
    override func mouseDown(with event: NSEvent) {
        guard let text = documentView as? NSTextView, text.isEditable else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(text)
        let point = text.convert(event.locationInWindow, from: nil)
        if text.bounds.contains(point) { text.mouseDown(with: event) } else { text.moveToEndOfDocument(nil) }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        if let text = documentView as? NSTextView { return window?.makeFirstResponder(text) ?? false }
        return super.becomeFirstResponder()
    }
}
