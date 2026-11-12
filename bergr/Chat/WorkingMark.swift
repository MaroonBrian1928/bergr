import SwiftUI

/// The mark beside "Thinking…": eight small strokes that make a little moving picture (orbits,
/// gears, a spinner, a twinkle, a wave, dots, a ripple) and flow into the next
/// picture when it changes. Drawn here rather than with SF Symbols, whose effects mostly move
/// the whole symbol; here the parts move, each with a rhythm of its own (nothing at constant
/// speed), and lines are thinner than dots so the pictures read at this size.
struct WorkingMark: View {
    /// Which picture (any integer; wraps).
    let index: Int
    /// The picture before it, and when the change began: the mark flows from that one into this
    /// one. Given by the caller (it knows when the picture changes), so the very first frame of a
    /// change is already part of the flow, with no frame of the new picture before it.
    var previous: Int?
    var changedAt: Date = .distantPast
    let color: Color
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// False once the mark has left the screen (a lazy list removes it): its timeline then stops.
    @State private var onScreen = true

    static let count = Pattern.allCases.count
    /// How long one picture takes to become the next: slow enough to watch it happen.
    static let morphDuration = 1.1
    /// How long one picture stays on screen before the next (the mark's keyframes cover it).
    static let pictureDuration = 6.0

    var body: some View {
        Group {
            #if os(macOS)
            if LayerMotion.on { layer } else { canvas }
            #else
            canvas
            #endif
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }

    private var canvas: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !onScreen)) { context in
            Canvas { gc, canvas in
                let r = min(canvas.width, canvas.height) / 2
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                for s in Self.strokes(index: index, previous: previous, changedAt: changedAt, at: context.date,
                                      reduceMotion: reduceMotion) {
                    s.draw(in: &gc, center: center, radius: r, color: color)
                }
            }
        }
    }

    /// The mark's strokes at a moment: the picture's own motion, and its flow out of the one before.
    static func strokes(index: Int, previous: Int?, changedAt: Date, at date: Date, reduceMotion: Bool) -> [Stroke] {
        let t = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate
        let now = Pattern.at(index)
        let p = date.timeIntervalSince(changedAt) / morphDuration
        let morphing = !reduceMotion && previous != nil && p < 1 && p >= 0
        let from = Pattern.at(previous ?? index)
        // Pairs fixed for the whole change (taken at its start), so no stroke switches partner midway.
        let pairs = morphing ? Stroke.pairs(from: from, to: now, at: changedAt.timeIntervalSinceReferenceDate)
                             : []
        let k = Ease.smoother(p)
        // The whole mark turns a little as it changes, so the strokes sweep together.
        let swirl = morphing ? sin(.pi * k) * 0.5 : 0
        return (0..<Stroke.count).map { i in
            let s = now.stroke(i, t)
            return morphing ? Stroke.mix(from.stroke(pairs[i], t), s, k).turned(swirl) : s
        }
    }
}

#if os(macOS)
extension WorkingMark {
    /// On the Mac the mark is a few layers whose pictures are Core Animation keyframes, so the
    /// window server moves it and the app does nothing per frame. As a `TimelineView` it had SwiftUI
    /// draw the whole window's view tree again on every frame, for as long as an agent worked.
    private var layer: some View {
        MarkLayer(index: index, previous: previous, changedAt: changedAt, color: color, reduceMotion: reduceMotion)
    }
}

private struct MarkLayer: NSViewRepresentable {
    let index: Int
    let previous: Int?
    let changedAt: Date
    let color: Color
    let reduceMotion: Bool

    func makeNSView(context: Context) -> MarkView { MarkView() }

    func updateNSView(_ view: MarkView, context: Context) {
        view.index = index
        view.previous = previous
        view.changedAt = changedAt
        view.color = color.resolve(in: context.environment).cgColor
        view.reduceMotion = reduceMotion
        view.sync()
    }
}

/// The mark as eight stroke layers. Each picture is sampled over its time on screen (60 a second)
/// into keyframes for each stroke's path, width and opacity: the same frames the Canvas draws on
/// iOS, played by Core Animation. A change of picture, colour or size builds them again.
final class MarkView: NSView {
    var index = 0
    var previous: Int?
    var changedAt = Date.distantPast
    var color = CGColor(gray: 0, alpha: 1) {
        didSet { for l in strokeLayers { l.strokeColor = color } }
    }
    var reduceMotion = false
    private let strokeLayers: [CAShapeLayer] = (0..<Stroke.count).map { _ in
        let l = CAShapeLayer()
        l.fillColor = nil
        l.lineCap = .round
        return l
    }
    /// What the current animations were built for; nil when they are off (not on screen).
    private var built: Built?
    private var observers: [NSObjectProtocol] = []

    private struct Built: Equatable {
        var index: Int
        var previous: Int?
        var changedAt: Date
        var size: CGSize
        var reduceMotion: Bool
    }

    private static let sampleRate = 60.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for l in strokeLayers { layer?.addSublayer(l) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Without the implicit animation a layer's frame gets.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in strokeLayers { l.frame = bounds }
        CATransaction.commit()
        sync()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeVisibility()
        sync()
    }

    /// Visible on screen: its window is not occluded or minimized, and it is scrolled into view.
    private var isOnScreen: Bool {
        guard let window, window.occlusionState.contains(.visible) else { return false }
        return !visibleRect.isEmpty
    }

    /// Re-checks `sync()` when the window's occlusion or the enclosing scroll position changes.
    private func observeVisibility() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                            object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        })
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification,
                                                object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            })
        }
    }

    /// Brings the animations up to date. Off screen they are removed, so nothing runs for the mark.
    /// On screen they run from the picture's start, so the mark is at the same moment of its
    /// picture whenever it appears; with Reduce Motion it stands still on the picture.
    func sync() {
        guard window != nil, isOnScreen else {
            for l in strokeLayers { l.removeAllAnimations() }
            built = nil
            return
        }
        let now = Built(index: index, previous: previous, changedAt: changedAt, size: bounds.size,
                        reduceMotion: reduceMotion)
        if now == built, reduceMotion || strokeLayers[0].animation(forKey: "path") != nil { return }
        built = now
        for l in strokeLayers { l.removeAllAnimations() }
        guard bounds.width > 0 else { return }
        if reduceMotion {
            let strokes = WorkingMark.strokes(index: index, previous: nil, changedAt: .distantPast, at: .now,
                                              reduceMotion: true)
            for (l, s) in zip(strokeLayers, strokes) {
                l.path = path(for: s)
                l.lineWidth = max(1, s.width * radius)
                l.opacity = Float(s.opacity)
            }
            return
        }
        // Start at the picture's change, unless it is long over (then from now, with no morph).
        let duration = WorkingMark.pictureDuration
        let start = Date.now.timeIntervalSince(changedAt) < duration ? changedAt : .now
        let count = Int(duration * Self.sampleRate)
        var paths = Array(repeating: [CGPath](), count: Stroke.count)
        var widths = Array(repeating: [NSNumber](), count: Stroke.count)
        var opacities = Array(repeating: [NSNumber](), count: Stroke.count)
        for k in 0...count {
            let date = start.addingTimeInterval(Double(k) / Self.sampleRate)
            let strokes = WorkingMark.strokes(index: index, previous: previous, changedAt: changedAt, at: date,
                                              reduceMotion: false)
            for (i, s) in strokes.enumerated() {
                paths[i].append(path(for: s))
                widths[i].append(NSNumber(value: Double(max(1, s.width * radius))))
                opacities[i].append(NSNumber(value: Double(s.opacity)))
            }
        }
        let times = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        // The animations' local time starts at the picture's start, so now is that moment in it.
        let offset = max(0, Date.now.timeIntervalSince(start))
        for (i, l) in strokeLayers.enumerated() {
            l.path = paths[i].last
            l.lineWidth = CGFloat(widths[i].last?.doubleValue ?? 1)
            l.opacity = Float(opacities[i].last?.doubleValue ?? 1)
            let keys: [(String, [Any])] = [("path", paths[i]), ("lineWidth", widths[i]), ("opacity", opacities[i])]
            for (key, values) in keys {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.keyTimes = times
                a.calculationMode = .linear
                a.duration = duration
                a.timeOffset = offset
                a.fillMode = .forwards
                a.isRemovedOnCompletion = false
                l.add(a, forKey: key)
            }
        }
    }

    private var radius: CGFloat { min(bounds.width, bounds.height) / 2 }

    /// The stroke as a line in the layer's coordinates (y up). The picture is laid out top-left down,
    /// as the Canvas on iOS draws it, so each y is flipped here.
    private func path(for s: Stroke) -> CGPath {
        let r = radius
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let half = s.length / 2
        let dx = cos(s.angle) * half, dy = sin(s.angle) * half
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + x * r, y: bounds.height - (center.y + y * r))
        }
        let p = CGMutablePath()
        p.move(to: point(s.x - dx, s.y - dy))
        p.addLine(to: point(s.x + dx, s.y + dy))
        return p
    }
}
#endif

/// Curves for the motion: nothing in the mark moves at a constant speed.
enum Ease {
    /// Slow, fast, slow, with gentler ends than `inOut`: for the change from one picture to the next.
    static func smoother(_ x: Double) -> Double { let x = clamp(x); return x * x * x * (x * (6 * x - 15) + 10) }
    /// Slow, fast, slow.
    static func inOut(_ x: Double) -> Double { let x = clamp(x); return x * x * (3 - 2 * x) }
    /// Fast, then slowing down.
    static func out(_ x: Double) -> Double { let x = clamp(x); return 1 - pow(1 - x, 3) }
    /// Slow, then speeding up (falling).
    static func `in`(_ x: Double) -> Double { let x = clamp(x); return x * x }
    /// A critically damped spring from 0 to 1: quick, then settling, no overshoot.
    static func settle(_ x: Double) -> Double {
        // Scaled so it ends exactly at 1, with no jump when it's done.
        func s(_ x: Double) -> Double { 1 - (1 + 7 * x) * exp(-7 * x) }
        return s(clamp(x)) / s(1)
    }
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func frac(_ x: Double) -> Double { x - floor(x) }
    /// 0 at both ends, 1 in the middle: for fading something in and out over a cycle.
    static func bump(_ x: Double) -> Double { sin(.pi * clamp(x)) }
}

/// One stroke: a short line (or a dot when it has no length) in a -1…1 box.
struct Stroke {
    static let count = 8
    /// Lines are drawn thinner than dots: the contrast is what makes the pictures read small.
    static let line = 0.15, dot = 0.26

    var x: Double, y: Double
    var length: Double = 0
    var angle: Double = 0
    var width: Double = dot
    var opacity: Double = 1

    static func mix(_ a: Stroke, _ b: Stroke, _ k: Double) -> Stroke {
        func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * k }
        // Angles take the short way round.
        var d = (b.angle - a.angle).truncatingRemainder(dividingBy: .pi * 2)
        if d > .pi { d -= .pi * 2 } else if d < -.pi { d += .pi * 2 }
        return Stroke(x: l(a.x, b.x), y: l(a.y, b.y), length: l(a.length, b.length), angle: a.angle + d * k,
                      width: l(a.width, b.width), opacity: l(a.opacity, b.opacity))
    }

    /// Which old stroke each new stroke comes from: both sorted by their angle around the middle,
    /// so strokes travel round to their new places instead of crossing through the middle.
    static func pairs(from old: Pattern, to new: Pattern, at t: Double) -> [Int] {
        func order(_ p: Pattern) -> [Int] {
            (0..<count).sorted { a, b in
                let sa = p.stroke(a, t), sb = p.stroke(b, t)
                return atan2(sa.y, sa.x) < atan2(sb.y, sb.x)
            }
        }
        let o = order(old), n = order(new)
        var pairs = Array(repeating: 0, count: count)
        for k in 0..<count { pairs[n[k]] = o[k] }
        return pairs
    }

    /// Turned around the middle by `a` radians.
    func turned(_ a: Double) -> Stroke {
        var s = self
        (s.x, s.y) = (x * cos(a) - y * sin(a), x * sin(a) + y * cos(a))
        s.angle += a
        return s
    }

    func draw(in gc: inout GraphicsContext, center: CGPoint, radius r: CGFloat, color: Color) {
        guard opacity > 0.01 else { return }
        let half = length / 2
        let dx = cos(angle) * half, dy = sin(angle) * half
        var path = Path()
        path.move(to: CGPoint(x: center.x + (x - dx) * r, y: center.y + (y - dy) * r))
        path.addLine(to: CGPoint(x: center.x + (x + dx) * r, y: center.y + (y + dy) * r))
        gc.stroke(path, with: .color(color.opacity(opacity)),
                  style: StrokeStyle(lineWidth: max(1, width * r), lineCap: .round))
    }
}

enum Pattern: CaseIterable {
    case orbit, gear, spinner, twinkle, wave, dots, ripple

    static func at(_ index: Int) -> Pattern {
        let all = allCases
        return all[((index % all.count) + all.count) % all.count]
    }

    func stroke(_ i: Int, _ t: Double) -> Stroke {
        let n = Double(Stroke.count), f = Double(i)
        switch self {
        case .orbit:
            // Three electrons on three tilted orbits, quick on one side and slow on the other
            // (like a real orbit), each a different speed; a small nucleus breathes in the middle.
            if i < 3 {
                let tilt = f * .pi / 3, w = 2.0 + f * 0.35
                let a = t * w + 0.45 * sin(t * w) + f * 2.1
                let ex = cos(a) * 0.86, ey = sin(a) * 0.32
                return Stroke(x: ex * cos(tilt) - ey * sin(tilt), y: ex * sin(tilt) + ey * cos(tilt))
            }
            let a = (f - 3) / 5 * .pi * 2 + t * 0.6
            let r = 0.1 + 0.03 * sin(t * 2.2)
            return Stroke(x: cos(a) * r, y: sin(a) * r, width: 0.22, opacity: 0.85)
        case .gear:
            // A wheel that clicks round a tooth at a time: a quick turn, then a rest.
            let beat = t / 0.9
            let turned = (floor(beat) + Ease.settle(min(1, Ease.frac(beat) / 0.55))) * (.pi / 4)
            let a = f / n * .pi * 2 + turned
            return Stroke(x: cos(a) * 0.6, y: sin(a) * 0.6, length: 0.34, angle: a, width: 0.2)
        case .spinner:
            // Spokes; a bright head runs round at an even pace, leaving a fading trail.
            let a = f / n * .pi * 2
            let head = t / 1.1 * n
            let age = Ease.frac((head - f) / n)
            return Stroke(x: cos(a) * 0.6, y: sin(a) * 0.6, length: 0.36, angle: a, width: Stroke.line,
                          opacity: 0.2 + 0.8 * pow(1 - age, 2))
        case .twinkle:
            // A four-point star whose arms reach out one after another, and sparks that glint.
            if i < 4 {
                let a = f * .pi / 2
                let reach = 0.7 + 0.3 * Ease.inOut(0.5 + 0.5 * sin(t * 2.4 - f * .pi / 2))
                return Stroke(x: cos(a) * 0.4 * reach, y: sin(a) * 0.4 * reach, length: 0.8 * reach,
                              angle: a, width: Stroke.line + 0.04)
            }
            let a = f * .pi / 2 + .pi / 4
            let glint = Ease.bump(Ease.frac(t * 0.55 + f * 0.27) * 2.5)
            return Stroke(x: cos(a) * 0.78, y: sin(a) * 0.78, width: 0.18 * glint + 0.04, opacity: glint)
        case .wave:
            // Bars rising and falling in one smooth wave that travels across them.
            let h = 0.3 + 0.7 * (0.5 + 0.5 * sin(t * 3.2 - f * 0.8))
            return Stroke(x: -0.8 + f * (1.6 / (n - 1)), y: 0, length: h * 1.5, angle: .pi / 2, width: 0.14)
        case .dots:
            // Typing dots that hop in turn, landing softly. The other strokes sit behind them, so a
            // change grows them out of the dots instead of out of nowhere.
            let k = i % 3
            let beat = Ease.frac(t / 1.2 - Double(k) * 0.16)
            let hop = beat < 0.4 ? Ease.bump(beat / 0.4) : 0
            return Stroke(x: -0.56 + Double(k) * 0.56, y: 0.1 - hop * 0.36, width: 0.28)
        case .ripple:
            // Two rings that spread out, fast then slowing, and fade as they go.
            let ring = i < 4 ? 0.0 : 0.5
            let grow = Ease.frac(t * 0.6 + ring)
            let a = f / 4 * .pi * 2 + (i < 4 ? 0 : .pi / 4)
            let r = 0.15 + Ease.out(grow) * 0.75
            return Stroke(x: cos(a) * r, y: sin(a) * r, width: 0.22, opacity: pow(1 - grow, 1.5))
        }
    }

    private func rotated(_ s: Stroke, _ a: Double) -> Stroke {
        var s = s
        (s.x, s.y) = (s.x * cos(a) - s.y * sin(a), s.x * sin(a) + s.y * cos(a))
        s.angle += a
        return s
    }
}
