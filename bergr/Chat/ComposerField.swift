import SwiftUI
import UIKit

/// The chat's reply box. A SwiftUI `TextField` only ever pastes text, so a copied screenshot
/// couldn't be pasted into it the way it can in Messages or Slack; this text view takes images
/// from Paste (and ⌘V) and hands them to `onPasteImages`, and pastes text as usual.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var textColor: UIColor
    var placeholderColor: UIColor
    var enabled = true
    var maxLines = 6
    var onPasteImages: ([UIImage]) -> Void

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "reply-field"
        view.placeholder.font = view.font
        view.placeholder.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text }
        view.textColor = textColor
        view.placeholder.text = placeholder
        view.placeholder.textColor = placeholderColor
        view.placeholder.isHidden = !text.isEmpty
        view.isEditable = enabled
        view.accessibilityLabel = placeholder
        view.onPasteImages = { onPasteImages($0) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 300
        let line = view.font?.lineHeight ?? 20
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(fitting, line), line * CGFloat(maxLines))
        // Past the last allowed line it scrolls inside instead of growing.
        let scrolls = fitting > height + 0.5
        if view.isScrollEnabled != scrolls { DispatchQueue.main.async { view.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: ceil(height))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerField
        init(parent: ComposerField) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            if parent.text != view.text { parent.text = view.text }
            (view as? PastingTextView)?.placeholder.isHidden = !view.text.isEmpty
            view.invalidateIntrinsicContentSize()
        }
    }
}

/// A text view whose Paste also takes images.
final class PastingTextView: UITextView {
    var onPasteImages: (([UIImage]) -> Void)?
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.numberOfLines = 1
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), isEditable, UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        // An image on the clipboard is what was copied (a screenshot, a photo); text that comes
        // along with it (a caption, a file name) isn't what the user means to paste.
        if board.hasImages, let images = board.images, !images.isEmpty, let onPasteImages {
            onPasteImages(images)
            return
        }
        super.paste(sender)
    }
}
