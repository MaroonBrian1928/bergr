import HerdrKit
import UIKit

/// Arrow keys from a held finger, like a joystick: past a small dead zone around where the hold
/// began, the direction the finger moved furthest in picks the key, and the distance picks how
/// fast it repeats.
enum ArrowStick {
    /// How fast the key repeats, slowest first.
    enum Speed: Int, Comparable {
        case slow
        case flow
        case fast

        static func < (a: Speed, b: Speed) -> Bool { a.rawValue < b.rawValue }
    }

    /// Closer than this to where the hold began: no key.
    static let deadZone: CGFloat = 22
    /// From this far on, keys repeat at flow speed.
    static let flowDistance: CGFloat = 70
    /// From this far on, keys repeat fast.
    static let fastDistance: CGFloat = 130
    /// How much further the finger must go along the other axis to switch it, so a drag that
    /// wobbles around a diagonal doesn't flip between two keys.
    static let axisStickiness: CGFloat = 1.3
    /// The first key goes out at once; repeating starts after this, as on a keyboard.
    static let repeatDelay: TimeInterval = 0.35
    static func interval(_ speed: Speed) -> TimeInterval {
        switch speed {
        case .slow: 0.25
        case .flow: 0.1
        case .fast: 0.03
        }
    }

    /// The key and speed for a finger this far from where the hold began; nil inside the dead
    /// zone. `current` is the key it gives now, for the stickiness.
    static func reading(dx: CGFloat, dy: CGFloat, current: TerminalKey?) -> (key: TerminalKey, speed: Speed)? {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= deadZone else { return nil }
        let wasHorizontal = current == .left || current == .right
        let wasVertical = current == .up || current == .down
        let horizontal =
            if wasHorizontal { abs(dx) * axisStickiness >= abs(dy) }
            else if wasVertical { abs(dx) > abs(dy) * axisStickiness }
            else { abs(dx) >= abs(dy) }
        let key: TerminalKey = horizontal ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
        let speed: Speed = distance >= fastDistance ? .fast : distance >= flowDistance ? .flow : .slow
        return (key, speed)
    }
}

/// Shows what the held finger does: four grey arrows, the active one lit. One key is an arrow;
/// repeating turns it into three chevrons: one lit (slow) or two (flow), running along with the
/// keys, or all three (fast).
final class ArrowPadView: UIView {
    enum Mode: Equatable {
        case idle
        case press(TerminalKey)
        /// `step` counts the keys sent, to move the lit chevrons along.
        case repeating(TerminalKey, ArrowStick.Speed, step: Int)
    }

    var mode: Mode {
        get { glyphs.mode }
        set { glyphs.mode = newValue }
    }

    /// Follows the terminal theme's brightness, like the title bar and keyboard: a light
    /// material with dark arrows over a light theme, a dark one over a dark theme.
    var dark = true {
        didSet {
            guard dark != oldValue else { return }
            overrideUserInterfaceStyle = dark ? .dark : .light
            layer.shadowOpacity = dark ? 0.35 : 0.12
            glyphs.setNeedsDisplay()
        }
    }

    static let size: CGFloat = 84
    private static let cornerRadius: CGFloat = 20

    private let material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let glyphs = Glyphs()

    override init(frame: CGRect) {
        super.init(frame: CGRect(origin: frame.origin, size: CGSize(width: Self.size, height: Self.size)))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        overrideUserInterfaceStyle = .dark
        // Lifts it off the text below; the material itself is clipped to the rounded shape.
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: Self.cornerRadius).cgPath
        material.frame = bounds
        material.layer.cornerRadius = Self.cornerRadius
        material.layer.cornerCurve = .continuous
        material.clipsToBounds = true
        material.layer.borderWidth = 1 / 3
        addSubview(material)
        glyphs.frame = bounds
        glyphs.isOpaque = false
        glyphs.backgroundColor = .clear
        addSubview(glyphs)
        updateBorder()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _) in self.updateBorder() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func updateBorder() {
        material.layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// The arrows, drawn over the material.
    private final class Glyphs: UIView {
        var mode: Mode = .idle {
            didSet { if mode != oldValue { setNeedsDisplay() } }
        }

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            let dim = UIColor.tertiaryLabel.resolvedColor(with: traitCollection)
            let lit = UIColor.systemBlue.resolvedColor(with: traitCollection)
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let offset = bounds.width / 2 - 16
            // Each slot is drawn pointing left, then turned into place.
            let slots: [(TerminalKey, CGPoint, CGFloat)] = [
                (.left, CGPoint(x: center.x - offset, y: center.y), 0),
                (.right, CGPoint(x: center.x + offset, y: center.y), .pi),
                (.up, CGPoint(x: center.x, y: center.y - offset), .pi / 2),
                (.down, CGPoint(x: center.x, y: center.y + offset), -.pi / 2),
            ]
            for (key, point, angle) in slots {
                context.saveGState()
                context.translateBy(x: point.x, y: point.y)
                context.rotate(by: angle)
                switch mode {
                case .press(key):
                    drawArrow(color: lit)
                case .repeating(key, let speed, let step):
                    // As many lit as the speed's stage, running from the back to the tip.
                    let count = speed.rawValue + 1
                    drawChevrons { index in (step - (2 - index) + 3) % 3 < count ? lit : dim }
                default:
                    drawArrow(color: dim)
                }
                context.restoreGState()
            }
        }

        /// An arrow pointing left, centred on the origin.
        private func drawArrow(color: UIColor) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 7, y: 0))
            path.addLine(to: CGPoint(x: -7, y: 0))
            path.move(to: CGPoint(x: -1.5, y: -5.5))
            path.addLine(to: CGPoint(x: -7, y: 0))
            path.addLine(to: CGPoint(x: -1.5, y: 5.5))
            stroke(path, color: color)
        }

        /// Three chevrons pointing left, centred on the origin; index 0 is the tip.
        private func drawChevrons(color: (Int) -> UIColor) {
            for index in 0..<3 {
                let x = -8.25 + CGFloat(index) * 5.5
                let path = UIBezierPath()
                path.move(to: CGPoint(x: x + 5.5, y: -6.5))
                path.addLine(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x + 5.5, y: 6.5))
                stroke(path, color: color(index))
            }
        }

        private func stroke(_ path: UIBezierPath, color: UIColor) {
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
    }
}
