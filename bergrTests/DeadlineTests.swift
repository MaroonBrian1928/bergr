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
        let start = ContinuousClock.now
        // Ignores cancellation, like a request on a dead SSH channel.
        let ok = await Deadline.answers(within: .milliseconds(100)) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        #expect(ok == false)
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func networkSignatureIgnoresOrder() {
        #expect(NetworkWatcher.signature(satisfied: true, interfaces: ["wifi-en0", "other-utun3"])
                == NetworkWatcher.signature(satisfied: true, interfaces: ["other-utun3", "wifi-en0"]))
        #expect(NetworkWatcher.signature(satisfied: true, interfaces: ["wifi-en0"])
                != NetworkWatcher.signature(satisfied: true, interfaces: ["cellular-pdp_ip0"]))
    }
}
