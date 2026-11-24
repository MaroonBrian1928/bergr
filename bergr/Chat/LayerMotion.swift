import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Motion that never stops while an agent works (the spinner in the list, the shimmer over
// "Thinking…", the working mark in `WorkingMark.swift`), moved by Core Animation.
//
// As SwiftUI animations each of them had SwiftUI go over the window's view tree again on every
// frame the display shows, on the main thread: a third of it on the Mac for as long as an agent
// worked, and on the phone enough to keep it hot. A layer animation runs in the render server and
// costs the app nothing. What is drawn is the same.

/// Whether these are on: `-bergr.swiftUIMotion YES` brings the SwiftUI animations back, to compare.
@MainActor
enum LayerMotion {
    static var on = !UserDefaults.standard.bool(forKey: "bergr.swiftUIMotion")
}

#if os(macOS)
/// One representable for both platforms: `makeView` / `updateView` stand for the NS or UI versions.
protocol PlatformViewRepresentable: NSViewRepresentable {
    associatedtype PlatformView: NSView
    func makeView(context: Context) -> PlatformView
    func updateView(_ view: PlatformView, context: Context)
}

extension PlatformViewRepresentable {
    func makeNSView(context: Context) -> PlatformView { makeView(context: context) }
    func updateNSView(_ view: PlatformView, context: Context) { updateView(view, context: context) }
}

/// A layer-backed view that ignores the pointer and says when it is laid out and when it may have
/// come on or gone off screen.
class MotionView: NSView {
    private var observers: [NSObjectProtocol] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var hostLayer: CALayer { layer! }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        laidOut()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        visibilityChanged()
    }

    /// Visible on screen: its window is not occluded or minimized, and it is scrolled into view.
    var isOnScreen: Bool {
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return !visibleRect.isEmpty
    }

    func laidOut() {}
    func visibilityChanged() {}

    /// Re-checks when the window's occlusion or the enclosing scroll position changes.
    private func observeVisibility() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityChanged() }
        })
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            })
        }
    }
}
#else
protocol PlatformViewRepresentable: UIViewRepresentable {
    associatedtype PlatformView: UIView
    func makeView(context: Context) -> PlatformView
    func updateView(_ view: PlatformView, context: Context)
}

extension PlatformViewRepresentable {
    func makeUIView(context: Context) -> PlatformView { makeView(context: context) }
    func updateUIView(_ view: PlatformView, context: Context) { updateView(view, context: context) }
}

class MotionView: UIView {
    private var observers: [NSObjectProtocol] = []
    private var appActive = UIApplication.shared.applicationState == .active

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let center = NotificationCenter.default
        // Layer animations are dropped in the background: started again on becoming active.
        let names: [(Notification.Name, Bool)] = [
            (UIApplication.didBecomeActiveNotification, true),
            (UIApplication.willResignActiveNotification, false),
            (UIApplication.didEnterBackgroundNotification, false),
        ]
        for (name, active) in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appActive = active
                    self?.visibilityChanged()
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var hostLayer: CALayer { layer }

    override func layoutSubviews() {
        super.layoutSubviews()
        laidOut()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        visibilityChanged()
    }

    /// In a window with the app active. Not the scroll position: nothing re-checks it as a list
    /// scrolls, a lazy list removes rows it scrolls away, and a layer animation off screen costs the
    /// app nothing.
    var isOnScreen: Bool {
        window != nil && appActive && !isHidden
    }

    func laidOut() {}
    func visibilityChanged() {}
}
#endif

/// The ring that turns while an agent works: most of a circle, once round a second.
struct SpinnerRing: PlatformViewRepresentable {
    let color: Color
    var lineWidth: CGFloat = 2

    func makeView(context: Context) -> SpinnerRingView { SpinnerRingView() }

    func updateView(_ view: SpinnerRingView, context: Context) {
        view.ring.strokeColor = color.resolve(in: context.environment).cgColor
        view.ring.lineWidth = lineWidth
    }
}

final class SpinnerRingView: MotionView {
    let ring = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ring.fillColor = nil
        ring.lineCap = .round
        ring.strokeStart = 0.12
        ring.strokeEnd = 1
        hostLayer.addSublayer(ring)
    }

    override func laidOut() {
        // Without the implicit animation a layer's frame gets.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds, transform: nil)
        CATransaction.commit()
        spin()
    }

    override func visibilityChanged() { spin() }

    /// Off screen the animation is removed; a layer also loses it when it leaves the window or the
    /// app goes to the background: started again when it is back.
    private func spin() {
        guard isOnScreen else { ring.removeAnimation(forKey: "spin"); return }
        guard ring.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        // Clockwise as seen, whichever way up the layer's coordinates are.
        #if os(macOS)
        turn.toValue = (ring.contentsAreFlipped() ? 1 : -1) * 2 * Double.pi
        #else
        turn.toValue = 2 * Double.pi
        #endif
        turn.duration = 1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        ring.add(turn, forKey: "spin")
    }
}

/// The shimmer's band of light: a soft white stripe 0.6 of the width, which crosses from well
/// before the leading edge to well past the trailing one in 1.8 s, then rests for 1.2 s. The
/// stripe is drawn once by a gradient layer; only the layer moves.
struct ShimmerBand: PlatformViewRepresentable {
    func makeView(context: Context) -> ShimmerBandView { ShimmerBandView() }
    func updateView(_ view: ShimmerBandView, context: Context) {}
}

final class ShimmerBandView: MotionView {
    private let band = CAGradientLayer()
    private var sweptWidth: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        hostLayer.masksToBounds = true
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        band.colors = [white.copy(alpha: 0)!, white.copy(alpha: 0.55)!, white.copy(alpha: 0)!]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        // Out of sight until it moves: it rests before the leading edge, not over the text.
        band.isHidden = true
        hostLayer.addSublayer(band)
    }

    override func laidOut() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        band.frame = CGRect(x: 0, y: 0, width: bounds.width * 0.6, height: bounds.height)
        CATransaction.commit()
        sweep()
    }

    override func visibilityChanged() { sweep() }

    private func sweep() {
        let width = bounds.width
        guard isOnScreen, width > 0 else {
            band.removeAnimation(forKey: "sweep")
            band.isHidden = true
            return
        }
        if band.animation(forKey: "sweep") != nil, sweptWidth == width { return }
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
        band.add(cycle, forKey: "sweep")
        band.isHidden = false
    }
}
