import Foundation
import Testing
@testable import bergr

struct TerminalThrottleTests {
    @Test func coveredTerminalRendersLessOftenThanVisibleOne() {
        #expect(TerminalScreenModel.minInterval(drawing: true) == .milliseconds(8))
        #expect(TerminalScreenModel.minInterval(drawing: false) == .milliseconds(100))
    }
}
