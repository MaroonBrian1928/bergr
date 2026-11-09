import SwiftUI

/// The mark beside "Thinking…": eight small strokes that make a little moving picture (orbits,
/// gears, falling sand, a spinner, a twinkle, a wave, dots) and flow into the next picture when
/// the phrase changes. Drawn here rather than with SF Symbols, whose effects mostly move the
/// whole symbol; here the parts move.
struct WorkingMark: View {
    /// Which picture (any integer; wraps).
    let index: Int
    let color: Color
    var size: CGFloat = 18
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var from: Int?
    @State private var changed = Date.distantPast

    static let count = Pattern.allCases.count

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            Canvas { gc, canvas in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                let now = Pattern.at(index)
                let blend = from == nil ? 1 : min(1, context.date.timeIntervalSince(changed) / 0.6)
                let k = blend * blend * (3 - 2 * blend)  // smoothstep: eases in and out
                let r = min(canvas.width, canvas.height) / 2
                let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
                for i in 0..<Stroke.count {
                    var s = now.stroke(i, t)
                    if let from, k < 1 { s = Stroke.mix(Pattern.at(from).stroke(i, t), s, k) }
                    s.draw(in: &gc, center: center, radius: r, color: color)
                }
            }
        }
        .frame(width: size, height: size)
        .onChange(of: index) { old, _ in
            from = reduceMotion ? nil : old
            changed = .now
        }
        .accessibilityHidden(true)
    }
}

/// One stroke: a short line (or a dot when it has no length) in a -1…1 box.
struct Stroke {
    static let count = 8
    var x: Double, y: Double
    var length: Double
    var angle: Double
    var width: Double = 0.22
    var opacity: Double = 1

    static func mix(_ a: Stroke, _ b: Stroke, _ k: Double) -> Stroke {
        func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * k }
        // Angles take the short way round.
        var d = (b.angle - a.angle).truncatingRemainder(dividingBy: .pi * 2)
        if d > .pi { d -= .pi * 2 } else if d < -.pi { d += .pi * 2 }
        return Stroke(x: l(a.x, b.x), y: l(a.y, b.y), length: l(a.length, b.length), angle: a.angle + d * k,
                      width: l(a.width, b.width), opacity: l(a.opacity, b.opacity))
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
    case orbit, gear, hourglass, spinner, twinkle, wave, dots, ripple

    static func at(_ index: Int) -> Pattern {
        let all = allCases
        return all[((index % all.count) + all.count) % all.count]
    }

    func stroke(_ i: Int, _ t: Double) -> Stroke {
        let n = Double(Stroke.count), f = Double(i)
        switch self {
        case .orbit:
            // Three electrons on three tilted orbits, the rest a nucleus.
            if i < 3 {
                let tilt = f * .pi / 3, a = t * 2.4 + f * 2.1
                let ex = cos(a) * 0.9, ey = sin(a) * 0.36
                return Stroke(x: ex * cos(tilt) - ey * sin(tilt), y: ex * sin(tilt) + ey * cos(tilt),
                              length: 0, angle: 0, width: 0.26)
            }
            let a = f / 5 * .pi * 2 + t
            return Stroke(x: cos(a) * 0.12, y: sin(a) * 0.12, length: 0, angle: 0, width: 0.2,
                          opacity: 0.8)
        case .gear:
            // Teeth around a turning wheel.
            let a = f / n * .pi * 2 + t * 1.2
            return Stroke(x: cos(a) * 0.62, y: sin(a) * 0.62, length: 0.36, angle: a, width: 0.26)
        case .hourglass:
            // Sand falls from the top bulb to the bottom one, and the glass turns over.
            let flip = (t / 3).truncatingRemainder(dividingBy: 1)
            let turn = flip > 0.85 ? (flip - 0.85) / 0.15 * .pi : 0
            let fall = (t * 0.9 + f / n).truncatingRemainder(dividingBy: 1)
            var px: Double, py: Double
            if i < 2 {  // the two glass rims
                px = 0; py = i == 0 ? -0.85 : 0.85
                return rotated(Stroke(x: px, y: py, length: 1.0, angle: 0, width: 0.2), turn)
            }
            px = sin(f * 1.7) * 0.25 * (1 - fall)
            py = -0.6 + fall * 1.25
            return rotated(Stroke(x: px * (abs(py) + 0.15), y: py, length: 0, angle: 0, width: 0.2), turn)
        case .spinner:
            // Spokes that fade behind a turning head.
            let a = f / n * .pi * 2
            let head = (t * 1.6).truncatingRemainder(dividingBy: 1) * n
            let age = (head - f + n).truncatingRemainder(dividingBy: n) / n
            return Stroke(x: cos(a) * 0.62, y: sin(a) * 0.62, length: 0.42, angle: a, width: 0.2,
                          opacity: 1 - age * 0.8)
        case .twinkle:
            // A four-point star whose arms grow and shrink, with sparks around it.
            if i < 4 {
                let a = f * .pi / 2, pulse = 0.7 + 0.3 * sin(t * 4)
                return Stroke(x: cos(a) * 0.38 * pulse, y: sin(a) * 0.38 * pulse, length: 0.76 * pulse,
                              angle: a, width: 0.22)
            }
            let a = f * .pi / 2 + .pi / 4, blink = max(0, sin(t * 3 + f * 1.9))
            return Stroke(x: cos(a) * 0.82, y: sin(a) * 0.82, length: 0, angle: 0, width: 0.2,
                          opacity: blink)
        case .wave:
            // Bars rising and falling one after another.
            let h = 0.35 + 0.65 * abs(sin(t * 3 + f * 0.7))
            return Stroke(x: -0.84 + f * 0.24, y: 0, length: h * 1.6, angle: .pi / 2, width: 0.17)
        case .dots:
            // Typing dots: three hop in turn, the rest tucked behind them.
            let k = i % 3, hop = max(0, sin(t * 5 - Double(k) * 0.9))
            return Stroke(x: -0.6 + Double(k) * 0.6, y: -hop * 0.4, length: 0, angle: 0, width: 0.3,
                          opacity: i < 3 ? 1 : 0)
        case .ripple:
            // A ring of dots spreading out from the middle and fading.
            let grow = (t * 0.8 + (i < 4 ? 0 : 0.5)).truncatingRemainder(dividingBy: 1)
            let a = f / 4 * .pi * 2 + (i < 4 ? 0 : .pi / 4)
            return Stroke(x: cos(a) * grow * 0.9, y: sin(a) * grow * 0.9, length: 0, angle: 0, width: 0.22,
                          opacity: 1 - grow)
        }
    }

    private func rotated(_ s: Stroke, _ a: Double) -> Stroke {
        var s = s
        (s.x, s.y) = (s.x * cos(a) - s.y * sin(a), s.x * sin(a) + s.y * cos(a))
        s.angle += a
        return s
    }
}
