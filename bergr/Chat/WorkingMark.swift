import SwiftUI

/// The mark beside "Thinking…": eight small strokes that make a little moving picture (orbits,
/// gears, a spinner, a twinkle, a wave, dots, a ripple) and flow into the next
/// picture when it changes. Drawn here rather than with SF Symbols, whose effects mostly move
/// the whole symbol; here the parts move, each with a rhythm of its own (nothing at constant
/// speed), and lines are thinner than dots so the pictures read at this size.
struct WorkingMark: View {
    /// Which picture (any integer; wraps).
    let index: Int
    let color: Color
    var size: CGFloat = 20
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var morph: Morph?

    static let count = Pattern.allCases.count
    /// How long one picture takes to become the next.
    static let morphDuration = 0.55

    /// A change under way: the old picture, when it started, and which old stroke goes to which new one.
    private struct Morph {
        let from: Pattern
        let start: Date
        let pairs: [Int]
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { gc, canvas in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let now = Pattern.at(index)
                let r = min(canvas.width, canvas.height) / 2
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                let p = morph.map { min(1, context.date.timeIntervalSince($0.start) / Self.morphDuration) } ?? 1
                for i in 0..<Stroke.count {
                    var s = now.stroke(i, t)
                    if let morph, p < 1 {
                        s = Stroke.mix(morph.from.stroke(morph.pairs[i], t), s, Ease.settle(p))
                    }
                    s.draw(in: &gc, center: center, radius: r, color: color)
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: index) { old, new in
            guard !reduceMotion else { morph = nil; return }
            let t = Date.now.timeIntervalSinceReferenceDate
            morph = Morph(from: Pattern.at(old), start: .now,
                          pairs: Stroke.pairs(from: Pattern.at(old), to: Pattern.at(new), at: t))
        }
        .accessibilityHidden(true)
    }
}

/// Curves for the motion: nothing in the mark moves at a constant speed.
enum Ease {
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
            // Spokes; a bright head runs round, quick then easing, leaving a fading trail.
            let a = f / n * .pi * 2
            let lap = t / 1.1
            let head = (floor(lap) + Ease.inOut(Ease.frac(lap))) * n
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
            // Bars like a voice: two waves at different speeds, so it never quite repeats.
            let h = 0.3 + 0.7 * Ease.inOut(0.5 + 0.25 * sin(t * 3.1 + f * 0.75) + 0.25 * sin(t * 1.7 - f * 1.3))
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
