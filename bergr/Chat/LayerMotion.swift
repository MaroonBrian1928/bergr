#if os(macOS)
import AppKit
import SwiftUI

// Motion that never stops while an agent works (the spinner in the list, the shimmer over
// "Thinking…", the working mark in `WorkingMark.swift`), moved by Core Animation on the Mac.
//
// As SwiftUI animations each of them had SwiftUI go over the window's view tree again on every
// frame the display shows, on the main thread: a third of it for as long as an agent worked, which
// scrolling and live updates then had to share (the stutter). A layer animation runs in the
// window server and costs the app nothing. What is drawn is the same.

/// Whether these are on: `-bergr.swiftUIMotion YES` brings the SwiftUI animations back, to compare.
@MainActor
enum LayerMotion {
    static var on = !UserDefaults.standard.bool(forKey: "bergr.swiftUIMotion")
}

/// The ring that turns while an agent works: most of a circle, once round a second.
struct SpinnerRing: NSViewRepresentable {
    let color: Color
    var lineWidth: CGFloat = 2

    func makeNSView(context: Context) -> SpinnerRingView { SpinnerRingView() }

    func updateNSView(_ view: SpinnerRingView, context: Context) {
        view.ring.strokeColor = color.resolve(in: context.environment).cgColor
        view.ring.lineWidth = lineWidth
    }
}

final class SpinnerRingView: NSView {
    let ring = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeStart = 0.12
        ring.strokeEnd = 1
        layer?.addSublayer(ring)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Without the implicit animation a layer's frame gets.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
        spin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        spin()
    }

    /// A layer loses its animations when it leaves the window: started again when it is back.
    private func spin() {
        guard window != nil, ring.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise as seen, whichever way up the layer's coordinates are.
        turn.toValue = (ring.contentsAreFlipped() ? 1 : -1) * 2 * Double.pi
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: "spin")
    }
}

/// The shimmer's band of light: a soft white stripe 0.6 of the width, which crosses from well
/// before the leading edge to well past the trailing one in 1.8 s, then rests for 1.2 s. The
/// stripe itself is the same SwiftUI gradient as on iOS, drawn once; only its layer moves.
struct ShimmerBand: NSViewRepresentable {
    func makeNSView(context: Context) -> ShimmerBandView { ShimmerBandView() }
    func updateNSView(_ view: ShimmerBandView, context: Context) {}
}

final class ShimmerBandView: NSView {
    private let band = NSHostingView(rootView: LinearGradient(
        colors: [.clear, .white.opacity(0.55), .clear], startPoint: .leading, endPoint: .trailing))
    private var sweptWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = true
        band.sizingOptions = []
        // Out of sight until it moves: it rests before the leading edge, not over the text.
        band.isHidden = true
        addSubview(band)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        band.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.6, height: bounds.height)
        sweep()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sweep()
    }

    private func sweep() {
        let width = bounds.width
        guard window != nil, width > 0, let layer = band.layer else { return }
        if layer.animation(forKey: "sweep") != nil, sweptWidth == width { return }
        sweptWidth = width
        let move = CABasicAnimation(keyPath: "transform.translation.x")
        move.fromValue = -1.6 * width
        move.toValue = 1.6 * width
        // A sweep, then a rest: calmer next to the moving mark.
        move.beginTime = 1.2
        move.duration = 1.8
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.fillMode = .backwards
        let cycle = CAAnimationGroup()
        cycle.animations = [move]
        cycle.duration = 3
        cycle.repeatCount = .infinity
        cycle.isRemovedOnCompletion = false
        layer.add(cycle, forKey: "sweep")
        band.isHidden = false
    }
}
#endif
