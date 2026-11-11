import SwiftUI

/// Stub (chunk C replaces it with an `NSTextView`: Return sends, Shift-Return breaks the line,
/// image paste and drop). Same name and call shape as the iOS twin in `bergrIOS/Chat/ComposerField.swift`,
/// so `ChatView` is shared. For now a plain multi-line `TextField`.
struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    var textColor: PlatformColor
    var placeholderColor: PlatformColor
    var enabled = true
    var maxLines = 6
    var onPasteImages: ([PlatformImage]) -> Void

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(1...maxLines)
            .textFieldStyle(.plain)
            .foregroundStyle(Color(nsColor: textColor))
            .disabled(!enabled)
            .accessibilityIdentifier("reply-field")
    }
}
