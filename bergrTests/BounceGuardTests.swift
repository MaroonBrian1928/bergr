import Testing
import Foundation
@testable import bergr

struct BounceGuardTests {
    @Test func tripsOnRepeatedFlipping() {
        var g = BounceGuard()
        var tripped = false
        for i in 0..<10 { tripped = g.record(height: i % 2 == 0 ? 1000 : 1040, at: Double(i) * 0.2, userScrolling: false) || tripped }
        #expect(tripped)
        #expect(g.range == 1000...1040)
    }

    @Test func growingChatIsNotBouncing() {
        var g = BounceGuard()
        for i in 0..<40 { let t = g.record(height: 1000 + CGFloat(i) * 30, at: Double(i) * 0.1, userScrolling: false); #expect(!t) }
    }

    @Test func slowChangesDontTrip() {
        var g = BounceGuard()
        for i in 0..<12 { let t = g.record(height: i % 2 == 0 ? 1000 : 1040, at: Double(i) * 2, userScrolling: false); #expect(!t) }
    }

    @Test func userScrollingDoesntCount() {
        var g = BounceGuard()
        for i in 0..<12 { let t = g.record(height: i % 2 == 0 ? 1000 : 1040, at: Double(i) * 0.2, userScrolling: true); #expect(!t) }
    }

    @Test func resetFollowsAgain() {
        var g = BounceGuard()
        for i in 0..<10 { _ = g.record(height: i % 2 == 0 ? 1000 : 1040, at: Double(i) * 0.2, userScrolling: false) }
        g.reset()
        #expect(!g.tripped)
    }
}
