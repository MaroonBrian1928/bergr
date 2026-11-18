import Foundation

/// Spots the chat bouncing by itself: the list's height flipping up and down again and again with
/// nobody scrolling (a row whose height keeps changing, with the bottom anchor following it each
/// time). When it trips, the chat stops following size changes until the user scrolls or a new
/// message arrives, and the event is logged to Diagnostics.
nonisolated struct BounceGuard {
    /// Direction reversals within `window` seconds that count as bouncing.
    static let reversals = 6
    static let window: TimeInterval = 3

    private var last: CGFloat?
    private var lastSign = 0
    private var flips: [TimeInterval] = []
    private(set) var tripped = false
    /// The two heights it was flipping between, for the log.
    private(set) var range: ClosedRange<CGFloat>?

    /// Records a new content height. Returns true the moment it trips.
    mutating func record(height: CGFloat, at now: TimeInterval, userScrolling: Bool) -> Bool {
        defer { last = height }
        guard let last, !tripped else { return false }
        if userScrolling { flips.removeAll(); lastSign = 0; return false }
        let delta = height - last
        guard abs(delta) >= 1 else { return false }
        let sign = delta > 0 ? 1 : -1
        if lastSign != 0, sign != lastSign {
            flips.append(now)
            range = min(range?.lowerBound ?? height, height, last)...max(range?.upperBound ?? height, height, last)
        }
        lastSign = sign
        flips.removeAll { now - $0 > Self.window }
        if flips.count >= Self.reversals { tripped = true; return true }
        return false
    }

    /// Follows size changes again (the user scrolled, or a message arrived).
    mutating func reset() {
        tripped = false; flips.removeAll(); lastSign = 0; range = nil
    }
}
