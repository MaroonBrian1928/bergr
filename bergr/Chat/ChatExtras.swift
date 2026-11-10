import ImageIO
import SwiftUI

/// The agent's task list: what's done, what's under way, what's still to come.
struct PlanCard: View {
    let steps: [ChatFeed.PlanStep]
    let palette: ChatPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var done: Int { steps.filter { $0.status == "completed" }.count }
    private var motion: Animation { reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.35) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Plan")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 8)
                Text("\(done) of \(steps.count) done")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .monospacedDigit()
            }
            ForEach(steps.indices, id: \.self) { i in
                StepRow(step: steps[i], palette: palette, motion: motion)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.codeBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan, \(done) of \(steps.count) done")
    }

    private struct StepRow: View {
        let step: ChatFeed.PlanStep
        let palette: ChatPalette
        let motion: Animation

        private var completed: Bool { step.status == "completed" }
        private var inProgress: Bool { step.status == "in_progress" }
        private var symbol: String {
            switch step.status {
            case "completed": "checkmark.circle.fill"
            case "in_progress": "circle.inset.filled"
            default: "circle"
            }
        }
        private var status: String {
            switch step.status {
            case "completed": "done"
            case "in_progress": "in progress"
            default: "to do"
            }
        }

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(inProgress ? palette.accent : palette.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
                Text(step.text)
                    .font(.subheadline)
                    .fontWeight(inProgress ? .medium : .regular)
                    .foregroundStyle(completed ? palette.secondary : palette.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 28, alignment: .top)
            .animation(motion, value: step.status)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(step.text), \(status)")
        }
    }
}

/// An image in the conversation. Tap to see it full size, and share it.
///
/// Decoding a JPEG is slow, and this view's body runs on every chat update: it shows a copy
/// shrunk to its display size, made once off the main thread and cached, and decodes the full
/// image only when opened.
/// An image to show full screen.
struct ViewedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

extension EnvironmentValues {
    /// Opens an image full screen from the screen that set it (the chat), not from the image's
    /// row: a row in the chat's lazy list can be rebuilt or dropped while its cover is up, which
    /// left a black screen with nothing to close it.
    @Entry var showImage: ((UIImage) -> Void)?
}

struct ImageBubble: View {
    let data: Data
    let fromUser: Bool
    let palette: ChatPalette
    @Environment(\.showImage) private var showImage
    @State private var thumb: UIImage?
    @State private var full: UIImage?
    @State private var showing = false

    var body: some View {
        Group {
            if let size = ImageThumbs.pixelSize(data) {
                Button {
                    guard let image = UIImage(data: data) else { return }
                    if let showImage { return showImage(image) }
                    full = image
                    showing = true
                } label: {
                    // Its own size, at most 240 × 260 and in proportion, so it sits against its side
                    // instead of in the middle of a wider box.
                    let scale = min(240 / max(size.width, 1), 260 / max(size.height, 1), 1)
                    let frame = CGSize(width: size.width * scale, height: size.height * scale)
                    ZStack {
                        palette.bubble
                        if let thumb { Image(uiImage: thumb).resizable() }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: fromUser ? .trailing : .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("Image")
                .accessibilityHint("Opens the image full screen, to zoom")
                .fullScreenCover(isPresented: $showing) {
                    // No zoom transition: its drag-to-close gesture took every pinch and pan.
                    if let full { ImageViewer(image: full) }
                }
            } else {
                Label("Image", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(palette.secondary)
                    .frame(maxWidth: .infinity, alignment: fromUser ? .trailing : .leading)
            }
        }
        .task(id: data.count) { thumb = await ImageThumbs.thumbnail(data) }
    }
}

/// Small copies of conversation images, for display.
enum ImageThumbs {
    private static let cache = NSCache<NSString, UIImage>()

    /// Width and height in points from the file's header, without decoding it.
    static func pixelSize(_ data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              var h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        if let o = props[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(o) { swap(&w, &h) }
        return CGSize(width: w, height: h)
    }

    /// A copy at most 260 points (in screen pixels) on its long side, decoded off the main thread.
    static func thumbnail(_ data: Data) async -> UIImage? {
        let key = "\(data.count)-\(data.prefix(64).hashValue)-\(data.suffix(64).hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let maxPixels = 260 * 3
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

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
