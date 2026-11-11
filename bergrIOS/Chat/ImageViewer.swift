import SwiftUI
import UIKit

/// Full screen, like Photos: pinch and double-tap to zoom, pan when zoomed, swipe down to close.
struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZoomableImage(image: image) { dismiss() }
                .ignoresSafeArea()
                .background(Color.black)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("Image", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share image")
                    }
                }
                .toolbarBackground(.hidden, for: .navigationBar)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Tells its owner each time it lays out.
private final class LayoutScrollView: UIScrollView {
    var onLayout: ((UIScrollView) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(self)
    }
}

/// UIKit's scroll view does the zooming: momentum, rubber-banding at the limits and centering
/// come with it, the way they do everywhere else on the phone.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    /// Pulling the unzoomed image down far enough closes the viewer.
    let onClose: () -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = LayoutScrollView()
        // Fit the image once the view knows its size, and again whenever the size changes;
        // SwiftUI's update can come before there is a size at all.
        scroll.onLayout = { [weak coordinator = context.coordinator] in coordinator?.layout($0) }
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 6
        scroll.bouncesZoom = true
        // Unzoomed, the image can still be pulled down (to close); it springs back otherwise.
        scroll.alwaysBounceVertical = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.backgroundColor = .clear

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.isAccessibilityElement = true
        view.accessibilityLabel = "Image"
        scroll.addSubview(view)
        context.coordinator.imageView = view

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.layout(scroll)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var imageView: UIImageView?
        private var laidOutFor: CGSize = .zero
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) { self.onClose = onClose }

        /// A firm pull down on the unzoomed image closes it; anything else is panning or zooming.
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 else { return }
            let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
            if pulled > 110 || (pulled > 40 && velocity.y < -1.2) { onClose() }
        }

        /// At zoom 1 the image fits the screen; done again when the screen's size changes.
        func layout(_ scroll: UIScrollView) {
            guard let imageView, let image = imageView.image, scroll.bounds.size != .zero,
                  scroll.bounds.size != laidOutFor else { return }
            laidOutFor = scroll.bounds.size
            scroll.zoomScale = 1
            let fit = min(scroll.bounds.width / image.size.width, scroll.bounds.height / image.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * fit,
                                                                 height: image.size.height * fit))
            scroll.contentSize = imageView.frame.size
            center(scroll)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) { center(scrollView) }

        /// Keeps a smaller-than-screen image in the middle instead of the top left.
        private func center(_ scroll: UIScrollView) {
            guard let imageView else { return }
            let x = max(0, (scroll.bounds.width - imageView.frame.width) / 2)
            let y = max(0, (scroll.bounds.height - imageView.frame.height) / 2)
            scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        }

        /// Double-tap zooms into the spot tapped, and back out.
        @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: imageView)
                let scale: CGFloat = 3
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
