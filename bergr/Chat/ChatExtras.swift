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
    let image: PlatformImage
}

extension EnvironmentValues {
    /// Opens an image full screen from the screen that set it (the chat), not from the image's
    /// row: a row in the chat's lazy list can be rebuilt or dropped while its cover is up, which
    /// left a black screen with nothing to close it.
    @Entry var showImage: ((PlatformImage) -> Void)?
}

struct ImageBubble: View {
    let data: Data
    let fromUser: Bool
    let palette: ChatPalette
    @Environment(\.showImage) private var showImage
    @State private var thumb: PlatformImage?
    @State private var full: PlatformImage?
    @State private var showing = false

    var body: some View {
        Group {
            if let size = ImageThumbs.pixelSize(data) {
                Button {
                    guard let image = PlatformImage(data: data) else { return }
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
                        if let thumb { Image(platformImage: thumb).resizable() }
                    }
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: fromUser ? .trailing : .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("Image")
                .accessibilityHint("Opens the image full screen, to zoom")
                .platformCover(isPresented: $showing) {
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
    private static let cache = NSCache<NSString, PlatformImage>()

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
    static func thumbnail(_ data: Data) async -> PlatformImage? {
        let key = "\(data.count)-\(data.prefix(64).hashValue)-\(data.suffix(64).hashValue)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let maxPixels = 260 * 3
        let image = await Task.detached(priority: .userInitiated) { () -> PlatformImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { PlatformImage.make(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

/// Where an image will be, while it arrives: its size (the same box an `ImageBubble` takes, so
/// nothing moves when it lands), softly pulsing.
struct ImagePlaceholder: View {
    let width: Double?
    let height: Double?
    let fromUser: Bool
    let palette: ChatPalette
    /// For an image held back on an expensive network: its size, and what a tap does.
    var sizeText: String? = nil
    var fetching = false
    var fetch: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        let w = max(width ?? 240, 1), h = max(height ?? 180, 1)
        let scale = min(240 / w, 260 / h, 1)
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(palette.bubble)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: fetch == nil ? "photo" : "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(palette.secondary.opacity(0.6))
                    if let sizeText, !fetching {
                        Text(sizeText).font(.caption2).foregroundStyle(palette.secondary)
                    }
                }
            }
            .frame(width: w * scale, height: h * scale)
            .opacity(fetch == nil || fetching ? (dim ? 0.55 : 1) : 1)
            .contentShape(Rectangle())
            .onTapGesture { if !fetching { fetch?() } }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: fromUser ? .trailing : .leading)
            .onAppear {
                guard !reduceMotion, fetch == nil || fetching else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityLabel(fetch == nil ? "Image, loading" : fetching ? "Image, loading" : "Image, tap to load")
    }
}
