import SwiftUI

/// Stub (chunk C fills it in): the image full size, with a Close button. The iOS twin lives in
/// `bergrIOS/Chat/ImageViewer.swift` (a zooming `UIScrollView`).
struct ImageViewer: View {
    let image: PlatformImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Image(platformImage: image).resizable().scaledToFit().frame(minWidth: 400, minHeight: 300)
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).padding(8)
        }
    }
}
