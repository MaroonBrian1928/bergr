import SwiftUI
import AppKit

/// A chat image full size: pinch to zoom, double-click to toggle fit and actual size,
/// Copy puts it on the pasteboard, Esc closes. The iOS twin is a zooming `UIScrollView`.
struct ImageViewer: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let fit = min(geo.size.width / max(image.size.width, 1), geo.size.height / max(image.size.height, 1), 1)
                let scale = fit * zoom * pinch
                ScrollView([.horizontal, .vertical]) {
                    Image(platformImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                        .frame(minWidth: geo.size.width, minHeight: geo.size.height)
                }
                .onTapGesture(count: 2) { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 1 / max(fit, 0.01) } }
                .gesture(MagnifyGesture().updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { zoom = min(max(zoom * $0.magnification, 0.25), 16) })
            }
            Divider()
            HStack {
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(8)
        }
        .frame(width: 800, height: 600)
        .accessibilityIdentifier("image-viewer")
    }
}
