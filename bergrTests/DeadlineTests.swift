import Testing
@testable import bergr

struct DeadlineTests {
    @Test func answerInTime() async {
        #expect(await Deadline.answers(within: .seconds(1)) { })
    }

    @Test func failureIsNoAnswer() async {
        struct Boom: Error {}
        #expect(await Deadline.answers(within: .seconds(1)) { throw Boom() } == false)
    }

    @Test func returnsAtTheLimitEvenIfTheWorkNeverAnswers() async {
        // Ignores cancellation, like a request on a dead SSH channel. Released after the check so
        // the work does not leak a never-resumed continuation into later tests.
        let latch = TestLatch()
        let start = ContinuousClock.now
        let ok = await Deadline.answers(within: .milliseconds(100)) {
            await latch.wait()
        }
        let elapsed = ContinuousClock.now - start
        latch.release()
        #expect(ok == false)
        // Generous bound: on a loaded simulator the timer task may start late. A task group
        // would never return here at all.
        #expect(elapsed < .seconds(10))
    }

    @Test func networkSignatureIgnoresOrder() {
        #expect(NetworkWatcher.signature(satisfied: true, interfaces: ["wifi-en0", "other-utun3"])
                == NetworkWatcher.signature(satisfied: true, interfaces: ["other-utun3", "wifi-en0"]))
        #expect(NetworkWatcher.signature(satisfied: true, interfaces: ["wifi-en0"])
                != NetworkWatcher.signature(satisfied: true, interfaces: ["cellular-pdp_ip0"]))
    }
}
