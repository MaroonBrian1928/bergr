import Testing
@testable import HerdrKit

@Test func firstSampleSetsSmoothedAndHalfVariation() {
    let rt = RoundTrip(first: .milliseconds(200))
    #expect(rt.smoothed == .milliseconds(200))
    #expect(rt.variation == .milliseconds(100))
    #expect(rt.timeout == .milliseconds(600))
}

@Test func steadySamplesConverge() {
    var rt = RoundTrip(first: .milliseconds(400))
    for _ in 0..<100 { rt.add(.milliseconds(100)) }
    #expect(rt.smoothed < .milliseconds(101))
    #expect(rt.variation < .milliseconds(1))
}

@Test func spikeGrowsVariationAndFollowsFormula() {
    var rt = RoundTrip(first: .milliseconds(100))
    for _ in 0..<50 { rt.add(.milliseconds(100)) }
    let before = rt.variation
    rt.add(.milliseconds(900))
    #expect(rt.variation > before)
    #expect(rt.smoothed > .milliseconds(190) && rt.smoothed < .milliseconds(201))
    #expect(rt.timeout == rt.smoothed + rt.variation * 4)
}

@Test func callRecordsRoundTrip() async throws {
    let client = try await HerdrClient.connectDemo()
    defer { Task { await client.close() } }
    _ = try await client.listTerminals()
    #expect(await client.roundTrip != nil)
}
