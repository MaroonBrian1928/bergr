import Testing
@testable import bergr

struct EchoPredictorTests {
    typealias Clock = ContinuousClock
    let t0 = Clock.now

    func type(_ p: inout EchoPredictor, _ s: String, enabled: Bool = true, latency: Duration? = .milliseconds(300),
              alt: Bool = false, cursor: (x: Int, y: Int)? = (5, 2), cols: Int = 80, at: Clock.Instant? = nil) {
        p.typed(s, enabled: enabled, latency: latency, alternateScreen: alt, cursor: cursor, cols: cols, now: at ?? t0)
    }

    func frame(_ p: inout EchoPredictor, row: String, y: Int = 2, cursor: (x: Int, y: Int)? = nil,
               alt: Bool = false, at: Clock.Instant? = nil) {
        var lines = ["", "", "", ""]
        lines[y] = row
        p.frameChanged(lines: lines, cursor: cursor, alternateScreen: alt, now: at ?? t0)
    }

    @Test func disabledPredictsNothing() {
        var p = EchoPredictor()
        type(&p, "a", enabled: false)
        let shown = p.shown
        #expect(shown == nil)
    }

    @Test func lowLatencyPredictsNothing() {
        var p = EchoPredictor()
        type(&p, "a", latency: .milliseconds(50))
        type(&p, "b", latency: nil)
        let shown = p.shown
        #expect(shown == nil)
    }

    @Test func alternateScreenPredictsNothing() {
        var p = EchoPredictor()
        type(&p, "a", alt: true)
        let shown = p.shown
        #expect(shown == nil)
    }

    @Test func predictsAtCursorAndExtends() {
        var p = EchoPredictor()
        type(&p, "a")
        var shown = p.shown
        #expect(shown == .init(row: 2, column: 5, text: "a"))
        type(&p, "bc")
        shown = p.shown
        #expect(shown == .init(row: 2, column: 5, text: "abc"))
    }

    @Test func rightEdgeRefused() {
        var p = EchoPredictor()
        type(&p, "ab", cursor: (79, 0), cols: 80)
        var shown = p.shown
        #expect(shown == nil)
        type(&p, "a", cursor: (79, 0), cols: 80)
        shown = p.shown
        #expect(shown == .init(row: 0, column: 79, text: "a"))
    }

    @Test func confirmationAdvances() {
        var p = EchoPredictor()
        type(&p, "abc")
        frame(&p, row: "     ab", cursor: (7, 2))
        var shown = p.shown
        #expect(shown == .init(row: 2, column: 7, text: "c"))
        frame(&p, row: "     abc", cursor: (8, 2))
        shown = p.shown
        #expect(shown == nil)
    }

    @Test func spaceNeedsCursorOrLaterChar() {
        var p = EchoPredictor()
        type(&p, "a ")
        frame(&p, row: "     a", cursor: (6, 2))
        let shown = p.shown
        #expect(shown == .init(row: 2, column: 6, text: " "))
    }

    @Test func mismatchClears() {
        var p = EchoPredictor()
        type(&p, "abc")
        frame(&p, row: "     ax", cursor: (7, 2))
        let shown = p.shown
        let suspended = p.suspended
        #expect(shown == nil)
        #expect(!suspended)
    }

    @Test func rowOrScreenChangeClears() {
        var p = EchoPredictor()
        type(&p, "a")
        frame(&p, row: "", cursor: (0, 3))
        var shown = p.shown
        #expect(shown == nil)
        type(&p, "a")
        frame(&p, row: "", cursor: (5, 2), alt: true)
        shown = p.shown
        #expect(shown == nil)
    }

    @Test func unconfirmedSuspendsUntilEnter() {
        var p = EchoPredictor()
        type(&p, "x")
        frame(&p, row: "", cursor: (5, 2), at: t0 + .milliseconds(1000))
        var shown = p.shown
        #expect(shown != nil)
        frame(&p, row: "", cursor: (5, 2), at: t0 + .milliseconds(1600))
        shown = p.shown
        var suspended = p.suspended
        #expect(shown == nil)
        #expect(suspended)
        type(&p, "y", at: t0 + .seconds(2))
        shown = p.shown
        #expect(shown == nil)
        type(&p, "\r")
        suspended = p.suspended
        #expect(!suspended)
        type(&p, "z")
        shown = p.shown
        #expect(shown != nil)
    }

    @Test func tickAppliesTimeout() {
        var p = EchoPredictor()
        type(&p, "x")
        p.tick(now: t0 + .milliseconds(1000))
        var shown = p.shown
        #expect(shown != nil)
        p.tick(now: t0 + .milliseconds(1500))
        shown = p.shown
        let suspended = p.suspended
        #expect(shown == nil)
        #expect(suspended)
    }

    @Test func nonPrintableAndBackspaceClear() {
        var p = EchoPredictor()
        for s in ["\u{7F}", "\u{08}", "\u{1B}[A", "a\nb", "\r", "é"] {
            type(&p, "a")
            type(&p, s)
            let shown = p.shown
            #expect(shown == nil, "\(s.debugDescription)")
        }
    }

    @Test func resetClearsAndUnsuspends() {
        var p = EchoPredictor()
        type(&p, "x")
        p.tick(now: t0 + .seconds(2))
        p.reset()
        let suspended = p.suspended
        #expect(!suspended)
        type(&p, "a")
        p.reset()
        let shown = p.shown
        #expect(shown == nil)
    }
}
